SHELL := /bin/bash
.DEFAULT_GOAL := help

KIND_NAME ?= linux-lab
WORKERS ?= 0
FILE ?=
IMAGE ?=
export KIND_NAME WORKERS FILE IMAGE
ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
KIND_SCRIPT := $(ROOT)kubernetes/kind/deploy-kind.sh

.PHONY: help kind-install kind-up kind-status kind-check kind-apply kind-load kind-logs kind-down
help:
	@bash "$(KIND_SCRIPT)" help

kind-install kind-up kind-status kind-check kind-apply kind-load kind-logs kind-down:
	@bash "$(KIND_SCRIPT)" "$(@:kind-%=%)"
