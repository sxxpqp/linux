# 镜像替代速查

记录"上游镜像废弃 / 改名后的替代关系",写 Dockerfile / docker-compose 时直接查。

| 旧镜像 | 新镜像 | 原因 / 备注 |
|---|---|---|
| `eclipse-temurin:8-jdk-alpine` | `openjdk:8-jdk-alpine` | eclipse-temurin 在 Docker Hub 上对 alpine 8 的 tag 维护不全,fallback 到 openjdk |
| `bitnamilegacy/redis:latest` | `bitnami/redis:latest` | bitnamilegacy 是 Bitnami 老命名空间,2024 后官方迁回 `bitnami/` |

## 维护建议

- 自己构建/调度的 image 出现"pull 不到"错误时,先查这里
- 新增映射时,顺手写明"为什么换"(版本兼容 / 镜像废弃 / 命名空间迁移 / 国内可达性 ...)
