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
plan:
	@bash "$(DIR)install.sh" $(ARGS)
install:
	@bash "$(DIR)install.sh" $(ARGS) --apply
guard:
	@test -n "$(CONTEXT)" || { echo '必须指定 CONTEXT'; exit 1; }
status: guard
	@$(K) -n kubesphere-system get pods,svc,pvc
logs: guard
	@$(K) -n kubesphere-system logs deployment/ks-installer --tail=200
