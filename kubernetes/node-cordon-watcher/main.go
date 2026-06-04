// node-cordon-watcher: 监控 K8s 节点 CPU/内存使用率,超过高水位自动 cordon,
// 降到低水位且持续一段时间后自动 uncordon。in-cluster 部署,leader election 保护。
//
// 设计要点见同目录 README.md / 仓库 CLAUDE.md。
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/leaderelection"
	"k8s.io/client-go/tools/leaderelection/resourcelock"
	metricsv "k8s.io/metrics/pkg/client/clientset/versioned"
)

// ==================== 常量 ====================

const (
	annotationManaged  = "node-cordon-watcher.sxxpqp.top/managed"
	annotationReason   = "node-cordon-watcher.sxxpqp.top/reason"
	annotationCordonAt = "node-cordon-watcher.sxxpqp.top/cordon-at"

	leaseName      = "node-cordon-watcher-leader"
	leaseNamespace = "monitoring"
)

// ==================== 配置 ====================

type Config struct {
	MetricSource     string        // metrics-api | prometheus
	PrometheusURL    string
	CheckInterval    time.Duration
	HighThreshold    float64
	LowThreshold     float64
	TriggerCount     int
	CooldownSeconds  int
	PerNodeCooldown  time.Duration
	MinHealthyNodes  int
	ExcludeLabels    []string
	IncludeLabels    []string
	DryRun           bool
	Notify           bool
	WxWebhookURL     string
	EnvName          string
	PodName          string
	PodNamespace     string
}

func loadConfig() Config {
	return Config{
		MetricSource:    getEnv("METRIC_SOURCE", "metrics-api"),
		PrometheusURL:   getEnv("PROMETHEUS_URL", "http://prometheus-k8s.monitoring.svc:9090"),
		CheckInterval:   getDuration("CHECK_INTERVAL", 30*time.Second),
		HighThreshold:   getFloat("HIGH_THRESHOLD", 80),
		LowThreshold:    getFloat("LOW_THRESHOLD", 70),
		TriggerCount:    getInt("TRIGGER_COUNT", 3),
		CooldownSeconds: getInt("COOLDOWN_SECONDS", 600),
		PerNodeCooldown: time.Duration(getInt("PER_NODE_COOLDOWN", 300)) * time.Second,
		MinHealthyNodes: getInt("MIN_HEALTHY_NODES", 1),
		ExcludeLabels:   splitCSV(getEnv("EXCLUDE_LABELS", "node-role.kubernetes.io/control-plane,node-role.kubernetes.io/master")),
		IncludeLabels:   splitCSV(getEnv("INCLUDE_LABELS", "")),
		DryRun:          getEnv("DRY_RUN", "false") == "true",
		Notify:          getEnv("NOTIFY", "true") == "true",
		WxWebhookURL:    getEnv("WX_WEBHOOK_URL", ""),
		EnvName:         getEnv("ENV_NAME", "生产"),
		PodName:         getEnv("POD_NAME", "unknown"),
		PodNamespace:    getEnv("POD_NAMESPACE", leaseNamespace),
	}
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func getFloat(key string, def float64) float64 {
	if v := os.Getenv(key); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}

func getDuration(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

func splitCSV(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// ==================== 指标源 ====================

type NodeUsage struct {
	CPUPercent float64
	MemPercent float64
}

type MetricSource interface {
	GetNodeUsage(ctx context.Context, node *corev1.Node) (NodeUsage, error)
	Name() string
}

// --- metrics.k8s.io 实现 ---

type metricsAPISource struct {
	client metricsv.Interface
}

func (m *metricsAPISource) Name() string { return "metrics-api" }

func (m *metricsAPISource) GetNodeUsage(ctx context.Context, node *corev1.Node) (NodeUsage, error) {
	nm, err := m.client.MetricsV1beta1().NodeMetricses().Get(ctx, node.Name, metav1.GetOptions{})
	if err != nil {
		return NodeUsage{}, fmt.Errorf("get NodeMetrics: %w", err)
	}
	allocCPU := node.Status.Allocatable[corev1.ResourceCPU]
	allocMem := node.Status.Allocatable[corev1.ResourceMemory]
	usedCPU := nm.Usage[corev1.ResourceCPU]
	usedMem := nm.Usage[corev1.ResourceMemory]

	cpuPct := pctOf(usedCPU, allocCPU)
	memPct := pctOf(usedMem, allocMem)
	return NodeUsage{CPUPercent: cpuPct, MemPercent: memPct}, nil
}

func pctOf(used, total resource.Quantity) float64 {
	t := total.AsApproximateFloat64()
	if t <= 0 {
		return 0
	}
	return used.AsApproximateFloat64() / t * 100
}

// --- Prometheus PromQL 实现 ---

type promQLSource struct {
	baseURL string
	http    *http.Client
}

func (p *promQLSource) Name() string { return "prometheus" }

type promResp struct {
	Status string `json:"status"`
	Data   struct {
		ResultType string          `json:"resultType"`
		Result     []promResultRow `json:"result"`
	} `json:"data"`
}

type promResultRow struct {
	Metric map[string]string `json:"metric"`
	Value  [2]interface{}    `json:"value"` // [timestamp, "value-string"]
}

func (p *promQLSource) query(ctx context.Context, q string) (float64, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", p.baseURL+"/api/v1/query", nil)
	if err != nil {
		return 0, err
	}
	qs := req.URL.Query()
	qs.Set("query", q)
	req.URL.RawQuery = qs.Encode()

	resp, err := p.http.Do(req)
	if err != nil {
		return 0, fmt.Errorf("prom query: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return 0, fmt.Errorf("prom http %d: %s", resp.StatusCode, body)
	}
	var pr promResp
	if err := json.Unmarshal(body, &pr); err != nil {
		return 0, fmt.Errorf("prom json: %w", err)
	}
	if pr.Status != "success" || len(pr.Data.Result) == 0 {
		return 0, fmt.Errorf("prom no data: %s", body)
	}
	vs, _ := pr.Data.Result[0].Value[1].(string)
	f, err := strconv.ParseFloat(vs, 64)
	if err != nil {
		return 0, fmt.Errorf("prom parse %q: %w", vs, err)
	}
	return f, nil
}

// kube-prometheus 的 node-exporter ServiceMonitor 用 relabeling 把
// __meta_kubernetes_pod_node_name 注入到 `instance` label(参见 nodeExporter-serviceMonitor.yaml),
// 不是 `node` label。所以筛选条件用 instance="<nodeName>"。
// 如果用户的 kube-prometheus 版本 relabel 到别的 label,可通过环境变量 PROM_NODE_LABEL 覆盖。
func (p *promQLSource) GetNodeUsage(ctx context.Context, node *corev1.Node) (NodeUsage, error) {
	name := node.Name
	lbl := getEnv("PROM_NODE_LABEL", "instance")
	cpuQ := fmt.Sprintf(`100 * (1 - avg by(%s) (rate(node_cpu_seconds_total{mode="idle",%s="%s"}[5m])))`, lbl, lbl, name)
	memQ := fmt.Sprintf(`100 * (1 - node_memory_MemAvailable_bytes{%s="%s"} / node_memory_MemTotal_bytes{%s="%s"})`, lbl, name, lbl, name)

	cpu, err := p.query(ctx, cpuQ)
	if err != nil {
		return NodeUsage{}, fmt.Errorf("cpu: %w", err)
	}
	mem, err := p.query(ctx, memQ)
	if err != nil {
		return NodeUsage{}, fmt.Errorf("mem: %w", err)
	}
	return NodeUsage{CPUPercent: cpu, MemPercent: mem}, nil
}

// ==================== 状态机 ====================

type nodeState struct {
	overCount     int       // 连续超 high 的次数
	belowSince    time.Time // 自动 uncordon:连续低于 low 的起始时间
	lastCordonAt  time.Time
	lastReason    string
}

type Decider struct {
	cfg    Config
	states map[string]*nodeState
	mu     sync.Mutex
}

type Action int

const (
	ActionNone Action = iota
	ActionCordon
	ActionUncordon
)

func (a Action) String() string {
	switch a {
	case ActionCordon:
		return "cordon"
	case ActionUncordon:
		return "uncordon"
	}
	return "none"
}

// Decide 计算单节点单次采样后应做的动作。
//   - alreadyCordoned:节点 spec.unschedulable 当前状态
//   - managed:是否是本 controller 之前 cordon 的(annotation)
func (d *Decider) Decide(name string, u NodeUsage, alreadyCordoned, managed bool, now time.Time) (Action, string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	st := d.states[name]
	if st == nil {
		st = &nodeState{}
		d.states[name] = st
	}

	overCPU := u.CPUPercent >= d.cfg.HighThreshold
	overMEM := u.MemPercent >= d.cfg.HighThreshold
	belowCPU := u.CPUPercent < d.cfg.LowThreshold
	belowMEM := u.MemPercent < d.cfg.LowThreshold

	// 1) 自动恢复路径:只能恢复"自己 cordon 的"节点
	if alreadyCordoned && managed {
		if belowCPU && belowMEM {
			if st.belowSince.IsZero() {
				st.belowSince = now
			}
			if now.Sub(st.belowSince) >= time.Duration(d.cfg.CooldownSeconds)*time.Second {
				st.belowSince = time.Time{}
				st.overCount = 0
				return ActionUncordon, "below-low-sustained"
			}
		} else {
			st.belowSince = time.Time{} // 中间有高过 low,重置
		}
		return ActionNone, ""
	}

	// 2) 节点已被(别人)cordon 但不是我们打的:不动它,但也不计数
	if alreadyCordoned && !managed {
		st.overCount = 0
		return ActionNone, ""
	}

	// 3) 正常调度状态 → 看是否要 cordon
	if overCPU || overMEM {
		st.overCount++
		if st.overCount >= d.cfg.TriggerCount {
			// 每节点冷却:距离上次 cordon 不够久,先按兵不动。
			// 同时重置计数,冷却期结束后还需要重新累积 TRIGGER_COUNT 次才会再触发。
			if !st.lastCordonAt.IsZero() && now.Sub(st.lastCordonAt) < d.cfg.PerNodeCooldown {
				st.overCount = 0
				return ActionNone, "per-node-cooldown"
			}
			reason := reasonFor(overCPU, overMEM)
			st.lastReason = reason
			st.lastCordonAt = now
			st.overCount = 0
			return ActionCordon, reason
		}
	} else {
		st.overCount = 0
	}
	return ActionNone, ""
}

func reasonFor(overCPU, overMEM bool) string {
	switch {
	case overCPU && overMEM:
		return "both"
	case overCPU:
		return "cpu-high"
	case overMEM:
		return "mem-high"
	}
	return ""
}

// 单元测试用:复位状态
func (d *Decider) resetForTest(name string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	delete(d.states, name)
}

// ==================== Controller ====================

type Controller struct {
	cfg        Config
	kc         kubernetes.Interface
	src        MetricSource
	decider    *Decider
	nodeLister cache.Store
}

func (c *Controller) shouldWatch(node *corev1.Node) (bool, string) {
	for _, l := range c.cfg.ExcludeLabels {
		if _, ok := node.Labels[l]; ok {
			return false, "excluded-by-label:" + l
		}
	}
	if len(c.cfg.IncludeLabels) > 0 {
		matched := false
		for _, l := range c.cfg.IncludeLabels {
			if _, ok := node.Labels[l]; ok {
				matched = true
				break
			}
		}
		if !matched {
			return false, "not-in-include-labels"
		}
	}
	if !isNodeReady(node) {
		return false, "not-ready"
	}
	return true, ""
}

func isNodeReady(n *corev1.Node) bool {
	for _, c := range n.Status.Conditions {
		if c.Type == corev1.NodeReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
}

// countHealthyWorkers:正在被调度的 worker 数量(reay + 非 unschedulable + 在监控范围)
func (c *Controller) countHealthyWorkers() int {
	count := 0
	for _, obj := range c.nodeLister.List() {
		n := obj.(*corev1.Node)
		if ok, _ := c.shouldWatch(n); !ok {
			continue
		}
		if n.Spec.Unschedulable {
			continue
		}
		count++
	}
	return count
}

func (c *Controller) tick(ctx context.Context) {
	for _, obj := range c.nodeLister.List() {
		n := obj.(*corev1.Node)
		ok, why := c.shouldWatch(n)
		if !ok && !n.Spec.Unschedulable {
			// 不在监控范围且未 cordon → 跳过
			continue
		}
		// 即使不在监控范围,如果它是我们之前 cordon 的(annotation managed),也要继续判断恢复
		managed := n.Annotations[annotationManaged] == "true"
		if !ok && !managed {
			log.Printf("[skip] node=%s reason=%s", n.Name, why)
			continue
		}

		u, err := c.src.GetNodeUsage(ctx, n)
		if err != nil {
			log.Printf("[metric-err] node=%s err=%v", n.Name, err)
			continue
		}
		act, reason := c.decider.Decide(n.Name, u, n.Spec.Unschedulable, managed, time.Now())
		log.Printf("[sample] node=%s cpu=%.1f%% mem=%.1f%% cordoned=%v managed=%v action=%s reason=%s",
			n.Name, u.CPUPercent, u.MemPercent, n.Spec.Unschedulable, managed, act, reason)

		switch act {
		case ActionCordon:
			healthy := c.countHealthyWorkers()
			if healthy-1 < c.cfg.MinHealthyNodes {
				log.Printf("[guard] node=%s refuse-cordon healthy=%d min=%d", n.Name, healthy, c.cfg.MinHealthyNodes)
				c.notify(n.Name, u, "guard-min-healthy", "skip-cordon")
				continue
			}
			c.doCordon(ctx, n, reason, u)
		case ActionUncordon:
			c.doUncordon(ctx, n, u)
		}
	}
}

func (c *Controller) doCordon(ctx context.Context, n *corev1.Node, reason string, u NodeUsage) {
	if c.cfg.DryRun {
		log.Printf("[DRY-RUN] would cordon node=%s reason=%s cpu=%.1f%% mem=%.1f%%",
			n.Name, reason, u.CPUPercent, u.MemPercent)
		c.notify(n.Name, u, reason, "[DRY-RUN] cordon")
		return
	}
	patch := map[string]interface{}{
		"spec": map[string]interface{}{"unschedulable": true},
		"metadata": map[string]interface{}{
			"annotations": map[string]string{
				annotationManaged:  "true",
				annotationReason:   reason,
				annotationCordonAt: time.Now().UTC().Format(time.RFC3339),
			},
		},
	}
	if err := c.patchNode(ctx, n.Name, patch); err != nil {
		log.Printf("[cordon-err] node=%s err=%v", n.Name, err)
		return
	}
	log.Printf("[cordon] node=%s reason=%s cpu=%.1f%% mem=%.1f%%", n.Name, reason, u.CPUPercent, u.MemPercent)
	c.notify(n.Name, u, reason, "cordon")
}

func (c *Controller) doUncordon(ctx context.Context, n *corev1.Node, u NodeUsage) {
	if c.cfg.DryRun {
		log.Printf("[DRY-RUN] would uncordon node=%s cpu=%.1f%% mem=%.1f%%", n.Name, u.CPUPercent, u.MemPercent)
		c.notify(n.Name, u, "below-low-sustained", "[DRY-RUN] uncordon")
		return
	}
	patch := map[string]interface{}{
		"spec": map[string]interface{}{"unschedulable": false},
		"metadata": map[string]interface{}{
			"annotations": map[string]interface{}{
				annotationManaged:  nil,
				annotationReason:   nil,
				annotationCordonAt: nil,
			},
		},
	}
	if err := c.patchNode(ctx, n.Name, patch); err != nil {
		log.Printf("[uncordon-err] node=%s err=%v", n.Name, err)
		return
	}
	log.Printf("[uncordon] node=%s cpu=%.1f%% mem=%.1f%%", n.Name, u.CPUPercent, u.MemPercent)
	c.notify(n.Name, u, "below-low-sustained", "uncordon")
}

func (c *Controller) patchNode(ctx context.Context, name string, patch map[string]interface{}) error {
	data, err := json.Marshal(patch)
	if err != nil {
		return err
	}
	_, err = c.kc.CoreV1().Nodes().Patch(ctx, name, types.StrategicMergePatchType, data, metav1.PatchOptions{})
	if apierrors.IsNotFound(err) {
		return nil
	}
	return err
}

// ==================== 通知(企微 webhook) ====================

func (c *Controller) notify(node string, u NodeUsage, reason, action string) {
	if !c.cfg.Notify || c.cfg.WxWebhookURL == "" {
		return
	}
	icon := "🚨"
	color := 2
	if strings.Contains(action, "uncordon") {
		icon, color = "✅", 3
	}
	title := fmt.Sprintf("%s [%s] node %s %s", icon, c.cfg.EnvName, node, action)

	card := map[string]interface{}{
		"msgtype": "template_card",
		"template_card": map[string]interface{}{
			"card_type": "text_notice",
			"source": map[string]interface{}{
				"desc":       fmt.Sprintf("node-cordon-watcher【%s】", c.cfg.EnvName),
				"desc_color": color,
			},
			"main_title": map[string]interface{}{
				"title": title,
				"desc":  fmt.Sprintf("CPU=%.1f%%  MEM=%.1f%%", u.CPUPercent, u.MemPercent),
			},
			"horizontal_content_list": []map[string]interface{}{
				{"keyname": "节点", "value": node},
				{"keyname": "动作", "value": action},
				{"keyname": "原因", "value": reason},
				{"keyname": "CPU%", "value": fmt.Sprintf("%.1f", u.CPUPercent)},
				{"keyname": "MEM%", "value": fmt.Sprintf("%.1f", u.MemPercent)},
				{"keyname": "时间", "value": time.Now().In(time.FixedZone("CST", 8*3600)).Format("2006-01-02 15:04:05")},
			},
			"card_action": map[string]interface{}{"type": 1, "url": "https://kubernetes.io"},
		},
	}
	body, _ := json.Marshal(card)
	hc := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
	resp, err := hc.Post(c.cfg.WxWebhookURL, "application/json", bytes.NewReader(body))
	if err != nil {
		log.Printf("[notify-err] %v", err)
		return
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
}

// ==================== 启动 ====================

func newMetricSource(cfg Config, restCfg *rest.Config) (MetricSource, error) {
	switch cfg.MetricSource {
	case "metrics-api", "":
		mc, err := metricsv.NewForConfig(restCfg)
		if err != nil {
			return nil, err
		}
		return &metricsAPISource{client: mc}, nil
	case "prometheus":
		return &promQLSource{
			baseURL: strings.TrimRight(cfg.PrometheusURL, "/"),
			http:    &http.Client{Timeout: 10 * time.Second},
		}, nil
	default:
		return nil, fmt.Errorf("unknown METRIC_SOURCE=%s", cfg.MetricSource)
	}
}

func run(ctx context.Context, cfg Config, kc kubernetes.Interface, src MetricSource) {
	factory := informers.NewSharedInformerFactory(kc, 5*time.Minute)
	nodeInformer := factory.Core().V1().Nodes().Informer()
	store := nodeInformer.GetStore()
	factory.Start(ctx.Done())
	log.Printf("waiting informer cache sync...")
	if !cache.WaitForCacheSync(ctx.Done(), nodeInformer.HasSynced) {
		log.Fatal("informer cache sync timeout")
	}
	log.Printf("informer cache synced, %d nodes", len(store.List()))

	ctrl := &Controller{
		cfg:        cfg,
		kc:         kc,
		src:        src,
		decider:    &Decider{cfg: cfg, states: map[string]*nodeState{}},
		nodeLister: store,
	}

	tick := time.NewTicker(cfg.CheckInterval)
	defer tick.Stop()
	ctrl.tick(ctx) // 立即跑一次
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			ctrl.tick(ctx)
		}
	}
}

func runLeaderElected(ctx context.Context, cfg Config, kc kubernetes.Interface, src MetricSource) {
	lock := &resourcelock.LeaseLock{
		LeaseMeta: metav1.ObjectMeta{Name: leaseName, Namespace: cfg.PodNamespace},
		Client:    kc.CoordinationV1(),
		LockConfig: resourcelock.ResourceLockConfig{
			Identity: cfg.PodName,
		},
	}
	leaderelection.RunOrDie(ctx, leaderelection.LeaderElectionConfig{
		Lock:            lock,
		ReleaseOnCancel: true,
		LeaseDuration:   30 * time.Second,
		RenewDeadline:   20 * time.Second,
		RetryPeriod:     5 * time.Second,
		Callbacks: leaderelection.LeaderCallbacks{
			OnStartedLeading: func(c context.Context) {
				log.Printf("became leader: %s", cfg.PodName)
				run(c, cfg, kc, src)
			},
			OnStoppedLeading: func() {
				log.Printf("lost leader: %s", cfg.PodName)
			},
			OnNewLeader: func(id string) {
				if id != cfg.PodName {
					log.Printf("new leader observed: %s", id)
				}
			},
		},
	})
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	cfg := loadConfig()
	log.Printf("config: %+v", cfg)

	restCfg, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("InClusterConfig: %v", err)
	}
	kc, err := kubernetes.NewForConfig(restCfg)
	if err != nil {
		log.Fatalf("kubernetes client: %v", err)
	}
	src, err := newMetricSource(cfg, restCfg)
	if err != nil {
		log.Fatalf("metric source: %v", err)
	}
	log.Printf("metric source: %s", src.Name())

	ctx, cancel := context.WithCancel(context.Background())
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		s := <-sigCh
		log.Printf("signal: %v, shutting down", s)
		cancel()
	}()

	// 健康检查 endpoint(给 livenessProbe 用)
	go func() {
		mux := http.NewServeMux()
		mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "ok") })
		log.Println(http.ListenAndServe(":8080", mux))
	}()

	runLeaderElected(ctx, cfg, kc, src)
}
