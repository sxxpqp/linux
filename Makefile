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

kind-install kind-up kind-status kind-check kind-apply kind-load kind-logs kind-down kind-config kind-ingress kind-use kind-unuse:
	@bash "$(KIND_SCRIPT)" "$(@:kind-%=%)"

kind-uninstall: kind-down
