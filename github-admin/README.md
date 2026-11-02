# 可复现运维与 GitHub 仓库资产管理

本目录将 GitHub 资产盘点从“网页点击/口头记录”变为**Git 中可审查的配置和命令**。它不执行删除、归档或自动修改仓库。

## 项目标准：配置即代码

- **实际部署**：Docker Compose、Kubernetes Manifest、版本锁定、安装/升级/回滚脚本，不把网页点击作为唯一操作步骤。
- **交付文档**：每项变更写清环境条件、执行命令、验收、备份和回滚；通过 Git Commit / PR 审核。
- **安全配置**：只提交 .env.example 和非敏感模板；生产 Token、密码、私钥应由 Secret 管理系统或本地安全环境变量提供。
- **默认只读**：先收集现状和生成计划；对 archive、delete 等破坏性动作必须单独确认，并先完成恢复备份。
- **可复现不等于恢复旧历史**：只记录仓库 URL 并不能还原旧仓库全部 Git 对象、Issue、PR 和 Release。

## 本次清理操作的声明式记录

- [repositories.json](repositories.json)：7 个重点保留仓库，以及 5 个“2026-11-02 核对时不再可见”的上游源码副本与原项目地址。
- [audit.sh](audit.sh)：使用 GitHub CLI 只读查询仓库清单，核对预期状态。
- reports/：本地 JSON 审计快照，可能包含私有仓库元数据，已配置忽略提交。

注意：not_visible 只表示当前认证账号查不到仓库，并不证明已永久删除。**配置文件不是删除指令**。

## 一条命令复现清点

要求 Linux、macOS 或 WSL，安装 gh、jq，并完成 gh auth login。

~~~bash
git clone https://github.com/sxxpqp/linux.git
cd linux
gh auth status
bash github-admin/audit.sh
~~~

检查本地生成的清单：

~~~bash
jq -r '.[].nameWithOwner' github-admin/reports/*.json
~~~

脚本仅读取数据，不会 Star、Fork、Archive、Delete 或更改权限。若权限不足或结果不完整，不要把“查不到”当作“已删除”。

## 将来归档/删除的工作流

1. 在配置和 PR 中记录目标、原因、上游仓库与影响。
2. 核对个人独有提交、Tag、Release、Issue、PR 和依赖。
3. 先使用 git clone --mirror 备份 Git 历史到独立存储；必要时单独导出 Issue/PR/Release 数据。
4. 提交变更计划审核，单独授权后才允许执行破坏性命令。
5. 保存操作结果、时间与恢复说明，勿以网页记录作为唯一证据。

## 不同项目分别存放代码与配置

| 任务 | 项目仓库 | 应保留的内容 |
| --- | --- | --- |
| Headscale + DERP + Headplane | [headscale-derp-stack](https://github.com/sxxpqp/headscale-derp-stack) | Compose、K8s、HTTPS、配置示例、验证与回滚 |
| 运维工具链 | [opskit](https://github.com/sxxpqp/opskit) | CI、K8s E2E、版本、部署和恢复 |
| 运维知识库 | [linux](https://github.com/sxxpqp/linux) | 脚本、配置、故障手册及 GitHub 资产管理 |
| 镜像/下载代理 | [opskit-mirror](https://github.com/sxxpqp/opskit-mirror) / [opskit-cloud](https://github.com/sxxpqp/opskit-cloud) | 转发规则、证书、访问控制与测试 |

不要将所有项目强行合并到一个仓库；统一的是**可复现交付规范**，各项目仍可独立演进。
