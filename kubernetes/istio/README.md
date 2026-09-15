# Istio 服务网格

包含 Istio 服务网格相关配置与离线/在线引导脚本。

## 目录文件说明

- `downloadIstioCandidate.sh`: Istio 候选版本下载与引导脚本

## 快速使用

指定版本下载 Istio 安装包：

```bash
ISTIO_VERSION=1.20.0 TARGET_ARCH=x86_64 TARGET_OS=Linux bash downloadIstioCandidate.sh
```

更多 Istio 配置示例请参考 [kubernetes/README.md](../README.md)。
