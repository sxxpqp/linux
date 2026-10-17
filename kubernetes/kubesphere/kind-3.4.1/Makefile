# 执行逻辑在 install.sh；Makefile 只提供命令入口和可覆盖的配置。
SHELL := /bin/bash -eu -o pipefail
.DEFAULT_GOAL := help
DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
KIND_NAME ?= kubesphere-341
KUBE_CONFIG ?= $(HOME)/.kube/kind-$(KIND_NAME).config
PASSWORD_FILE ?= $(HOME)/.kube/$(KIND_NAME).admin-password
TOOLS_DIR ?= $(HOME)/.cache/linux-kubesphere-341/bin
INSTALLER_SOURCE ?= registry.cn-beijing.aliyuncs.com/kubesphereio/ks-installer:v3.4.1

export KIND_NAME KUBE_CONFIG PASSWORD_FILE TOOLS_DIR INSTALLER_SOURCE

.PHONY: help kind mirrors ks-install deploy status wait logs login use unuse down tools up guard images install

# 1. 安装 kind 工具并创建集群。
kind:
	@bash "$(DIR)install.sh" kind

# 2. 设置全部节点的镜像加速源。
mirrors:
	@bash "$(DIR)install.sh" mirrors

# 3. 安装 ks-installer 并等待 KubeSphere 就绪。
ks-install:
	@bash "$(DIR)install.sh" ks-install

# 按三步顺序执行；make -j deploy 也不会并行安装。
deploy:
	@$(MAKE) --no-print-directory -f "$(DIR)Makefile" kind
	@$(MAKE) --no-print-directory -f "$(DIR)Makefile" mirrors
	@$(MAKE) --no-print-directory -f "$(DIR)Makefile" ks-install

# 辅助命令和旧命令统一转发。
help status wait logs login use unuse down tools up guard images install:
	@bash "$(DIR)install.sh" "$@"
