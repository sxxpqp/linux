# nacos-docker

## ⚠ 这不是自己的模板

`nacos-docker-master/` 子目录是从 **Nacos 官方仓库 git clone 进来的源码**(`https://github.com/nacos-group/nacos-docker`),不是自己维护的 docker-compose 模板。

- `nacos-docker-master/` — 上游官方仓库快照,含 cluster / standalone / example 各种部署方式
- `bug.md` — 自己记录的踩坑笔记

## 用法

进官方目录跑:

```bash
cd nacos-docker-master
# 单机模式
docker compose -f example/standalone-derby.yaml up -d
# 集群模式
docker compose -f example/cluster-hostname.yaml up -d
```

## 维护建议

- 上游有更新时,直接在 `nacos-docker-master/` 里 `git pull`(它是一个独立的 git 子目录)
- 自己的踩坑/调参写到 `bug.md`,**不要直接改 `nacos-docker-master/` 里的文件**,否则下次 pull 会冲突
