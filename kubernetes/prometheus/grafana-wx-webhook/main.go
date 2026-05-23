package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// ==================== 配置 ====================

var (
	wxWebhookURL = getEnv("WX_WEBHOOK_URL",
		"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=6dd8d89f-a0a0-47e1-9992-81c16ab11582")
	grafanaURL = getEnv("GRAFANA_URL", "http://192.168.150.240:30909")
	listenAddr = getEnv("LISTEN_ADDR", ":5001")
	envName    = getEnv("ENV_NAME", "生产") // 环境标识：测试、预发、生产
)

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// ==================== Grafana/Alertmanager Payload ====================

type AlertPayload struct {
	Alerts []Alert `json:"alerts"`
	// Grafana 新版单条告警格式
	Alert      *SingleAlert `json:"alert,omitempty"`
	NotifiedAt string       `json:"notified_at,omitempty"`
}

type SingleAlert struct {
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations"`
}

type Alert struct {
	Status       string            `json:"status"`
	Labels       map[string]string `json:"labels"`
	Annotations  map[string]string `json:"annotations"`
	StartsAt     string            `json:"startsAt"`
	GeneratorURL string            `json:"generatorURL,omitempty"`
	EndsAt       string            `json:"endsAt"`
}

// ==================== 企业微信消息结构 ====================

type WxMessage struct {
	MsgType      string        `json:"msgtype"`
	TemplateCard *TemplateCard `json:"template_card,omitempty"`
	Markdown     *Markdown     `json:"markdown,omitempty"`
}

type Markdown struct {
	Content string `json:"content"`
}

type TemplateCard struct {
	CardType              string              `json:"card_type"`
	Source                *CardSource         `json:"source,omitempty"`
	MainTitle             CardMainTitle       `json:"main_title"`
	EmphasisContent       *EmphasisContent    `json:"emphasis_content,omitempty"`
	HorizontalContentList []HorizontalContent `json:"horizontal_content_list,omitempty"`
	CardAction            CardAction          `json:"card_action"`
}

type CardSource struct {
	Desc      string `json:"desc"`
	DescColor int    `json:"desc_color"` // 0灰 1黑 2红 3绿
}

type CardMainTitle struct {
	Title string `json:"title"`
	Desc  string `json:"desc,omitempty"`
}

type EmphasisContent struct {
	Title string `json:"title"`
	Desc  string `json:"desc"`
}

type HorizontalContent struct {
	KeyName string `json:"keyname"`
	Value   string `json:"value"`
	Type    int    `json:"type,omitempty"`
	URL     string `json:"url,omitempty"`
}

type CardAction struct {
	Type int    `json:"type"` // 1=url
	URL  string `json:"url"`
}

// ==================== 时间转换 ====================

func toCSTString(isoStr string) string {
	if isoStr == "" || strings.HasPrefix(isoStr, "0001") {
		return "-"
	}
	isoStr = strings.Replace(isoStr, "Z", "+00:00", 1)
	layouts := []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02T15:04:05.999999999Z07:00",
	}
	cst := time.FixedZone("CST", 8*3600)
	for _, layout := range layouts {
		if t, err := time.Parse(layout, isoStr); err == nil {
			return t.In(cst).Format("2006-01-02 15:04:05")
		}
	}
	return isoStr
}

// ==================== 构建企业微信消息 ====================

func buildTemplateCard(alert Alert) WxMessage {
	lb := alert.Labels
	an := alert.Annotations

	alertName := labelOrDefault(lb, "alertname", "未知告警")
	severity := labelOrDefault(lb, "severity", "unknown")
	vhost := firstNonEmpty(lb["vhost"], lb["host"], lb["instance"], lb["node"], "-")
	serverPort := lb["server_port"]
	// 拼接端口，80/443 是标准端口不显示，其他端口显示
	if serverPort != "" && serverPort != "80" && serverPort != "443" {
		vhost = fmt.Sprintf("%s:%s", vhost, serverPort)
	}
	upstream := lb["upstream_addr"]
	namespace := lb["namespace"]
	summary := an["summary"]
	desc := firstNonEmpty(an["description"], an["message"], an["__value_string__"])
	startsAt := toCSTString(alert.StartsAt)
	endsAt := toCSTString(alert.EndsAt)

	// 替换 localhost 为真实 Grafana 地址
	alertURL := alert.GeneratorURL
	if alertURL == "" {
		alertURL = grafanaURL
	} else {
		alertURL = strings.ReplaceAll(alertURL, "http://localhost:3000", grafanaURL)
		alertURL = strings.ReplaceAll(alertURL, "https://localhost:3000", grafanaURL)
	}

	isFiring := alert.Status == "firing"

	title := fmt.Sprintf("🚨 [%s] %s", envName, alertName)
	sourceColor := 2 // 红色
	if !isFiring {
		title = fmt.Sprintf("✅ [%s] %s 已恢复", envName, alertName)
		sourceColor = 3 // 绿色
	}

	fields := []HorizontalContent{
		{KeyName: "域名", Value: vhost},
		{KeyName: "级别", Value: severity},
		{KeyName: "开始时间", Value: startsAt},
	}
	if upstream != "" {
		fields = append(fields, HorizontalContent{KeyName: "upstream", Value: upstream})
	}
	if namespace != "" {
		fields = append(fields, HorizontalContent{KeyName: "命名空间", Value: namespace})
	}
	if !isFiring && endsAt != "-" {
		fields = append(fields, HorizontalContent{KeyName: "恢复时间", Value: endsAt})
	}
	if desc != "" {
		maxLen := 50
		if len([]rune(desc)) > maxLen {
			desc = string([]rune(desc)[:maxLen]) + "..."
		}
		fields = append(fields, HorizontalContent{KeyName: "详情", Value: desc})
	}
	// Grafana 跳转链接
	fields = append(fields, HorizontalContent{
		KeyName: "查看面板",
		Value:   "点击跳转",
		Type:    1,
		URL:     alertURL,
	})

	return WxMessage{
		MsgType: "template_card",
		TemplateCard: &TemplateCard{
			CardType: "text_notice",
			Source:   &CardSource{Desc: fmt.Sprintf("Prometheus告警【%s】", envName), DescColor: sourceColor},
			MainTitle: CardMainTitle{
				Title: title,
				Desc:  summary,
			},
			EmphasisContent: &EmphasisContent{
				Title: strings.ToUpper(severity),
				Desc:  "告警级别",
			},
			HorizontalContentList: fields,
			CardAction:            CardAction{Type: 1, URL: alertURL},
		},
	}
}

// ==================== 发送到企业微信 ====================

func sendToWeixin(msg WxMessage) error {
	body, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("序列化失败: %w", err)
	}

	resp, err := http.Post(wxWebhookURL, "application/json", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("HTTP请求失败: %w", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	log.Printf("企业微信返回: %s", respBody)

	var result map[string]interface{}
	if err := json.Unmarshal(respBody, &result); err != nil {
		return fmt.Errorf("解析响应失败: %w", err)
	}
	if code, ok := result["errcode"].(float64); ok && code != 0 {
		return fmt.Errorf("企业微信错误: errcode=%v errmsg=%v", result["errcode"], result["errmsg"])
	}
	return nil
}

// ==================== HTTP Handler ====================

func webhookHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("读取请求体失败: %v", err)
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	defer r.Body.Close()
	log.Printf("收到payload: %s", string(body))

	var payload AlertPayload
	if err := json.Unmarshal(body, &payload); err != nil {
		log.Printf("JSON解析失败: %v", err)
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	alerts := payload.Alerts

	// 兼容 Grafana 新版单条告警格式
	if len(alerts) == 0 && payload.Alert != nil {
		alerts = []Alert{{
			Status:      "firing",
			Labels:      payload.Alert.Labels,
			Annotations: payload.Alert.Annotations,
			StartsAt:    payload.NotifiedAt,
			EndsAt:      "0001-01-01T00:00:00Z",
		}}
	}

	if len(alerts) == 0 {
		log.Println("未找到告警数据")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "no alerts")
		return
	}

	// 过滤掉系统级告警
	filterAlertNames := map[string]bool{
		"DatasourceNoData":  true,
		"DatasourceError":   true,
		" DatasourceNoData": true,
	}

	for _, alert := range alerts {
		if filterAlertNames[alert.Labels["alertname"]] {
			log.Printf("过滤告警 [%s]，跳过发送", alert.Labels["alertname"])
			continue
		}
		msg := buildTemplateCard(alert)
		if err := sendToWeixin(msg); err != nil {
			log.Printf("发送失败 [%s]: %v", alert.Labels["alertname"], err)
		} else {
			log.Printf("发送成功 [%s] status=%s labels=%v", alert.Labels["alertname"], alert.Status, alert.Labels)
		}
	}

	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "ok")
}

// ==================== 健康检查 ====================

func healthHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprint(w, "ok")
}

// ==================== 工具函数 ====================

func labelOrDefault(m map[string]string, key, def string) string {
	if v, ok := m[key]; ok && v != "" {
		return v
	}
	return def
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

// ==================== main ====================

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	log.Printf("wx-webhook 启动，监听 %s", listenAddr)
	log.Printf("企业微信 Webhook: %s...", wxWebhookURL[:60])
	log.Printf("Grafana 地址: %s", grafanaURL)
	log.Printf("当前环境: %s", envName)

	mux := http.NewServeMux()
	mux.HandleFunc("/", webhookHandler)
	mux.HandleFunc("/health", healthHandler)

	server := &http.Server{
		Addr:         listenAddr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("启动失败: %v", err)
	}
}
