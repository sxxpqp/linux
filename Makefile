SHELL := /bin/bash
.DEFAULT_GOAL := help

KIND_NAME ?= linux-lab
# 同时接受 WORKERS=2 和 workers=2，避免小写参数被静默忽略。
ifneq ($(origin workers),undefined)
ifneq ($(origin WORKERS),undefined)
ifneq ($(strip $(WORKERS)),$(strip $(workers)))
$(error WORKERS and workers have conflicting values)
endif
endif
WORKERS ?= $(workers)
endif
WORKERS ?= 0
FILE ?=
IMAGE ?=
export KIND_NAME WORKERS FILE IMAGE
ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
KIND_SCRIPT := $(ROOT)kubernetes/kind/deploy-kind.sh

.PHONY: help kind-install kind-up kind-status kind-check kind-apply kind-load kind-logs kind-down kind-uninstall kind-config kind-ingress kind-use kind-unuse
help:
	@bash "$(KIND_SCRIPT)" help

# 安装 kind 工具。
kind-install:
	@bash "$(KIND_SCRIPT)" install

# 创建 Kubernetes 测试集群。
kind-up:
	@bash "$(KIND_SCRIPT)" up

# 输出该集群的 kubeconfig 路径。
kind-config:
	@bash "$(KIND_SCRIPT)" config

# 安装 ingress 入口。
kind-ingress:
	@bash "$(KIND_SCRIPT)" ingress

# 应用业务清单或加载镜像。
kind-apply:
	@bash "$(KIND_SCRIPT)" apply

kind-load:
	@bash "$(KIND_SCRIPT)" load

# 辅助命令统一转发。
kind-status kind-check kind-logs kind-down kind-use kind-unuse:
	@bash "$(KIND_SCRIPT)" "$(@:kind-%=%)"

kind-uninstall: kind-down
