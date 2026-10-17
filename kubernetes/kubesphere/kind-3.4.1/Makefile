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

# 显示使用说明。
help:
	@bash "$(DIR)install.sh" help

# 查看节点、Pod、PVC 和控制台。
status:
	@bash "$(DIR)install.sh" status

# 等待核心服务和监控就绪。
wait:
	@bash "$(DIR)install.sh" wait

# 查看 ks-installer 日志。
logs:
	@bash "$(DIR)install.sh" logs

# 显示控制台地址和密码文件位置。
login:
	@bash "$(DIR)install.sh" login

# 切换到该集群 context。
use:
	@bash "$(DIR)install.sh" use

# 恢复切换前的 context。
unuse:
	@bash "$(DIR)install.sh" unuse

# 交互确认后删除测试集群。
down:
	@bash "$(DIR)install.sh" down

# 仅安装配套 kind 工具。
tools:
	@bash "$(DIR)install.sh" tools

# 创建或恢复集群，与 kind 入口相同。
up:
	@bash "$(DIR)install.sh" up

# 只读检查集群版本和端口。
guard:
	@bash "$(DIR)install.sh" guard

# 仅加载安装器镜像。
images:
	@bash "$(DIR)install.sh" images

# 仅提交安装器和组件配置；完整安装使用 ks-install。
install:
	@bash "$(DIR)install.sh" install
