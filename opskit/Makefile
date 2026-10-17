SHELL := /bin/bash -eu -o pipefail
.DEFAULT_GOAL := help
DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
.PHONY: help build test release

help:
	@printf '%s\n' 'make build   构建本机 bin/opskit' 'make test    运行安装器测试' 'make release 构建 Linux/macOS amd64+arm64、Windows amd64 发布包' '使用: bin/opskit kind install --version v0.17.0'

build:
	@cd "$(DIR)" && go build -trimpath -o bin/ .

test:
	@cd "$(DIR)" && go test ./...

release:
	@cd "$(DIR)"; for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64; do \
	  os=$${target%/*}; arch=$${target#*/}; suffix=''; \
	  if test "$$os" = windows; then suffix=.exe; fi; \
	  CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build -trimpath -o "dist/opskit-$$os-$$arch$$suffix" .; \
	done
