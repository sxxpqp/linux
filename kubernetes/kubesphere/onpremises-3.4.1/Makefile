SHELL := /bin/bash
.DEFAULT_GOAL := help
DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
KUBE_CONFIG ?= $(HOME)/.kube/config
CONTEXT ?=
NODES_FILE ?= $(DIR)nodes.secret
STORAGE_CLASS ?=
PASSWORD_FILE ?= $(HOME)/.kube/ks341-$(CONTEXT).secret
TIMEOUT ?= 900s
INSTALLER_SOURCE ?= docker.io/kubesphere/ks-installer:v3.4.1
ARGS = --kubeconfig "$(KUBE_CONFIG)" --context "$(CONTEXT)" --nodes-file "$(NODES_FILE)" --storage-class "$(STORAGE_CLASS)" --password-file "$(PASSWORD_FILE)" --timeout "$(TIMEOUT)" --installer-source "$(INSTALLER_SOURCE)"
K = kubectl --kubeconfig "$(KUBE_CONFIG)" --context "$(CONTEXT)" --request-timeout=30s
.PHONY: help plan install guard status logs
help:
	@printf '%s\n' '先 cp nodes.example nodes.secret 并填写全部节点 SSH 地址' 'make plan CONTEXT=<context> [KUBE_CONFIG=<file>]   只读预检' 'make install CONTEXT=<context>   更新所有节点镜像源后安装 KS 3.4.1' 'make status / logs CONTEXT=<context>   查看现有安装' '可选: STORAGE_CLASS=<sc> NODES_FILE=<file> PASSWORD_FILE=<file> TIMEOUT=900s'
# 1. 只读预检：集群版本、默认存储和全部节点连接。
plan:
	@bash "$(DIR)install.sh" $(ARGS)
# 2. 预检通过后更新节点镜像源，再安装 ks-installer。
install:
	@bash "$(DIR)install.sh" $(ARGS) --apply
# 辅助命令：确认目标 context 后查看状态和日志。
guard:
	@test -n "$(CONTEXT)" || { echo '必须指定 CONTEXT'; exit 1; }
status: guard
	@$(K) -n kubesphere-system get pods,svc,pvc
logs: guard
	@$(K) -n kubesphere-system logs deployment/ks-installer --tail=200
