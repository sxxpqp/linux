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

# 三步入口：make kind → make mirrors → make ks-install；make deploy 顺序执行全部。
help kind mirrors ks-install deploy status wait logs login use unuse down tools up guard images install:
	@bash "$(DIR)install.sh" "$@"
