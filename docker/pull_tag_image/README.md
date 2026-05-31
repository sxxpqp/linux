# pull_tag_image — 第三方镜像同步

把上游不稳定/被墙的镜像 pull 到本机,重新 tag 到 **自家阿里云 ACR**(`registry.cn-hangzhou.aliyuncs.com/sxxpqp/`),业务侧从 ACR 拉。

## 目录组织

按 `<产品名>/<版本号>/` 组织,方便对照上游 release 升级:

```
pull_tag_image/
├── dify/
│   ├── 1.0.1/      # Dify 1.0.1 镜像清单 + pull-tag-push 脚本
│   ├── 1.1.1/
│   └── 1.1.2/
└── ragflow/
    └── 0.17.2/
```

## 典型流程(各版本目录里的脚本干这个)

```bash
# 在能拉上游的机器上
docker pull <upstream>:<tag>
docker tag  <upstream>:<tag> registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>
docker login registry.cn-hangzhou.aliyuncs.com   # 用户名 sxxpqp
docker push registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>
```

之后业务/K8s yaml 里 image 直接写 `registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>`,国内节点直连阿里云足够快。

## 新增产品

按 `pull_tag_image/<new-product>/<version>/` 建目录,把镜像清单 + push 脚本放进去。复制现有 dify/ 目录改改即可。
