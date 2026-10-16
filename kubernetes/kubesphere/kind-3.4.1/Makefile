# macOS 自带 Make 3.81 不识别 .SHELLFLAGS，将失败即停选项直接交给 Bash。
SHELL := /bin/bash -eu -o pipefail
.DEFAULT_GOAL := help

DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(DIR)/../../..)
KIND_NAME ?= kubesphere-341
KUBE_CONFIG ?= $(HOME)/.kube/kind-$(KIND_NAME).config
PASSWORD_FILE ?= $(HOME)/.kube/$(KIND_NAME).admin-password
TOOLS_DIR ?= $(HOME)/.cache/linux-kubesphere-341/bin
KIND_BIN := $(TOOLS_DIR)/kind
INSTALLER_SOURCE ?= registry.cn-beijing.aliyuncs.com/kubesphereio/ks-installer:v3.4.1
INSTALLER_IMAGE := docker.io/kubesphere/ks-installer:v3.4.1
KUBECTL = kubectl --kubeconfig "$(KUBE_CONFIG)" --context "kind-$(KIND_NAME)"

.PHONY: help kind mirrors ks-install tools up guard images install deploy status wait logs login use unuse down
help:
	@printf '%s\n' \
	  'KubeSphere 3.4.1 / Kubernetes 1.24.7 / kind v0.17.0 测试环境' \
	  '1. make kind        安装配套 kind 工具并创建集群' \
	  '2. make mirrors     为全部 kind 节点设置镜像加速源并验证 CRI' \
	  '3. make ks-install  加载安装器、安装 KubeSphere 并等待就绪' \
	  'make deploy         按以上三步串行执行（需要 Docker、kubectl、Go、openssl、Python 3）' \
	  'make status   查看节点、Pod、PVC 与控制台 Service' \
	  'make wait     等待核心服务和监控 Pod 就绪' \
	  'make logs     查看安装器最近 80 行日志' \
	  'make login    显示控制台地址、用户名和密码文件位置（不打印密码）' \
	  'make use      切换默认 kubectl context；make unuse 恢复先前 context' \
	  'make down     输入集群名确认后删除该测试集群及数据' \
	  '默认控制台：http://127.0.0.1:30880；kind.yaml 固定映射该端口' \
	  'KIND_NAME 可覆盖；同时运行多个本目录集群时，须另行调整 kind.yaml 端口。' \
	  '以上三步不修改默认 context；只有 make use 才切换。'

kind: up

mirrors: tools guard
	@nodes=$$("$(KIND_BIN)" get nodes --name "$(KIND_NAME)"); \
	test -n "$$nodes" || { echo 'ERROR: 未找到 kind 节点。' >&2; exit 1; }; \
	for node in $$nodes; do \
	  echo "设置镜像加速源: $$node"; \
	  docker exec -i "$$node" bash -s -- --kind-config < "$(ROOT)/docker/containerd/mirrors.sh"; \
	  docker exec "$$node" systemctl --no-pager restart containerd; \
	  docker exec "$$node" crictl --runtime-endpoint unix:///run/containerd/containerd.sock info >/dev/null; \
	  docker exec "$$node" crictl --runtime-endpoint unix:///run/containerd/containerd.sock \
	    --image-endpoint unix:///run/containerd/containerd.sock pull docker.io/library/busybox:1.36; \
	  $(KUBECTL) wait --for=condition=Ready "node/$$node" --timeout=180s; \
	done

ks-install: guard
	@nodes=$$("$(KIND_BIN)" get nodes --name "$(KIND_NAME)"); \
	test -n "$$nodes"; \
	for node in $$nodes; do \
	  docker exec "$$node" test -s /etc/containerd/certs.d/docker.io/hosts.toml \
	    || { echo 'ERROR: 请先执行 make mirrors。' >&2; exit 1; }; \
	done
	@$(MAKE) --no-print-directory -f "$(DIR)Makefile" install
	@$(MAKE) --no-print-directory -f "$(DIR)Makefile" wait
	@$(MAKE) --no-print-directory -f "$(DIR)Makefile" login

tools:
	@if ! test -x "$(KIND_BIN)" || ! "$(KIND_BIN)" version | grep -q 'kind v0.17.0 '; then \
	  command -v go >/dev/null || { echo 'ERROR: 安装配套 kind 需要 Go。' >&2; exit 1; }; \
	  mkdir -p "$(TOOLS_DIR)"; \
	  GOBIN="$(TOOLS_DIR)" go install sigs.k8s.io/kind@v0.17.0; \
	fi

up: tools
	@command -v kubectl >/dev/null
	@docker info >/dev/null
	@clusters=$$("$(KIND_BIN)" get clusters); \
	if printf '%s\n' "$$clusters" | grep -Fxq -- "$(KIND_NAME)"; then \
	  echo '集群已存在，保留现有节点和数据。'; \
	  state=$$(docker inspect --format '{{.State.Status}}' "$(KIND_NAME)-control-plane"); \
	  case "$$state" in running) ;; exited|created) docker start "$(KIND_NAME)-control-plane";; \
	    *) echo "ERROR: 节点状态 $$state，请检查 Docker，未重建集群。" >&2; exit 1;; esac; \
	  "$(KIND_BIN)" export kubeconfig --name "$(KIND_NAME)" --kubeconfig "$(KUBE_CONFIG)"; \
	else \
	  mkdir -p "$$(dirname "$(KUBE_CONFIG)")"; \
	  "$(KIND_BIN)" create cluster --name "$(KIND_NAME)" --config "$(DIR)kind.yaml" \
	    --kubeconfig "$(KUBE_CONFIG)" --retain --wait 180s; \
	fi
	@ready=false; for ((i=0; i<30; i++)); do \
	  if $(KUBECTL) --request-timeout=2s get --raw=/readyz >/dev/null 2>&1; then ready=true; break; fi; \
	  sleep 2; \
	done; test "$$ready" = true || { echo 'ERROR: API 尚未就绪；未自动删除或重建集群。' >&2; exit 1; }
	@$(MAKE) --no-print-directory -f "$(DIR)Makefile" guard

guard:
	@test -f "$(KUBE_CONFIG)" || { echo 'ERROR: 缺少 kubeconfig，请先 make up。' >&2; exit 1; }
	@docker inspect "$(KIND_NAME)-control-plane" >/dev/null 2>&1 \
	  || { echo 'ERROR: 测试集群不存在或 Docker 不可用，请先 make up。' >&2; exit 1; }
	@version=$$($(KUBECTL) get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'); \
	case "$$version" in v1.24.*) ;; *) echo "ERROR: 要求 Kubernetes 1.24，当前为 $$version。" >&2; exit 1;; esac
	@docker port "$(KIND_NAME)-control-plane" 30880/tcp | grep -Fxq '127.0.0.1:30880' \
	  || { echo 'ERROR: 集群缺少预期 30880 映射，不自动删除重建。' >&2; exit 1; }

images: tools guard
	@docker image inspect "$(INSTALLER_SOURCE)" >/dev/null 2>&1 || docker pull "$(INSTALLER_SOURCE)"
	@docker tag "$(INSTALLER_SOURCE)" "$(INSTALLER_IMAGE)"
	@"$(KIND_BIN)" load docker-image "$(INSTALLER_IMAGE)" --name "$(KIND_NAME)"

install: images
	@command -v openssl >/dev/null
	@command -v python3 >/dev/null
	@umask 077; mkdir -p "$$(dirname "$(PASSWORD_FILE)")"; \
	if ! test -e "$(PASSWORD_FILE)"; then \
	  password="Ks341-$$(openssl rand -hex 16)"; \
	  (set -o noclobber; printf '%s\n' "$$password" > "$(PASSWORD_FILE)"); \
	fi; \
	test -s "$(PASSWORD_FILE)" || { echo 'ERROR: 密码文件为空。' >&2; exit 1; }; \
	password_json=$$(python3 -c 'import json,pathlib,re,sys; p=pathlib.Path(sys.argv[1]).read_text().rstrip("\n"); assert 8 <= len(p) <= 64 and all(re.search(x,p) for x in ("[a-z]","[A-Z]","[0-9]")), "密码必须为 8~64 字符并包含大小写字母和数字"; print(json.dumps(p))' "$(PASSWORD_FILE)"); \
	$(KUBECTL) apply -f "$(DIR)installer.yaml"; \
	$(KUBECTL) wait --for=condition=Established crd/clusterconfigurations.installer.kubesphere.io --timeout=30s; \
	KS_ADMIN_PASSWORD_JSON="$$password_json" awk \
	  '/^[ ]+jwtSecret:/ {printf "    adminPassword: %s\n", ENVIRON["KS_ADMIN_PASSWORD_JSON"]} {print}' \
	  "$(DIR)cluster-configuration.yaml" | $(KUBECTL) apply -f -

# 递归执行确保 make -j deploy 仍严格按三步顺序执行。
deploy:
	@$(MAKE) --no-print-directory -f "$(DIR)Makefile" kind
	@$(MAKE) --no-print-directory -f "$(DIR)Makefile" mirrors
	@$(MAKE) --no-print-directory -f "$(DIR)Makefile" ks-install

status: guard
	@$(KUBECTL) get nodes -o wide
	@$(KUBECTL) get pods -A
	@$(KUBECTL) get pvc -A
	@$(KUBECTL) -n kubesphere-system get service ks-console

wait: guard
	@$(KUBECTL) -n kubesphere-system wait --for=jsonpath='{.status.core.status}'=enabled clusterconfiguration/ks-installer --timeout=600s
	@for app in ks-apiserver ks-console ks-controller-manager; do \
	  $(KUBECTL) -n kubesphere-system rollout status "deployment/$$app" --timeout=600s; \
	done
	@$(KUBECTL) -n kubesphere-monitoring-system wait --for=condition=Ready pods --all --timeout=600s

logs: guard
	@$(KUBECTL) -n kubesphere-system logs deployment/ks-installer --tail=80

login:
	@printf '%s\n' '控制台：http://127.0.0.1:30880' '用户名：admin' '密码文件：$(PASSWORD_FILE)'
	@test -s "$(PASSWORD_FILE)" || { echo 'ERROR: 密码文件不存在或为空。' >&2; exit 1; }

use unuse:
	@KIND_NAME="$(KIND_NAME)" KUBECONFIG="$(KUBECONFIG)" bash "$(ROOT)/kubernetes/kind/deploy-kind.sh" "$@"

down: tools
	@test -t 0 || { echo 'ERROR: 删除需要在交互终端确认。' >&2; exit 1; }
	@read -r -p '删除 $(KIND_NAME) 及全部集群数据，输入集群名确认: ' answer; \
	test "$$answer" = "$(KIND_NAME)" || { echo '已取消。' >&2; exit 1; }; \
	"$(KIND_BIN)" delete cluster --name "$(KIND_NAME)" --kubeconfig "$(KUBE_CONFIG)"
