# Ansible 自动化

Ansible 自动化配置管理与 ad-hoc 命令示例。

## 文件说明

| 文件 | 说明 |
|---|---|
| [centos.yaml](centos.yaml) | CentOS 7 初始化 Playbook（多 tasks 合集）：安装 EPEL 源、更换阿里云 YUM 源、安装 Docker 并启动开机自启、pip 安装 docker-compose |
| [hello_world.yml](hello_world.yml) | Ansible 入门示例：echo hello world、apt 更新缓存、安装 vim（含 become sudo 权限演示） |
| [hosts](hosts) | Ansible Inventory 示例：3 节点（server1/2/3），分组 web/db/cache，SSH 端口映射 2222/2223/2224 |
| [Dockerfile](Dockerfile) | Ansible 测试环境镜像：基于 ubuntu:18.04，安装 systemd + sshd，创建 turing 用户（sudo 权限） |
| [docker-compose.yaml](docker-compose.yaml) | Ansible 3 节点测试环境编排：privileged 模式启动 ubuntu1804:test，端口映射 2222/2223/2224 |

## Ad-hoc 命令速查

```bash
# 文件操作
ansible -i hosts all -m file -a "path=/tmp/test state=directory"
ansible -i hosts all -m copy -a "src=/etc/hosts dest=/tmp/hosts backup=yes"

# 服务管理
ansible -i hosts all -m systemd -a "name=nginx state=reloaded"

# YUM 源管理
ansible -i hosts all -m yum_repository -a "name=epel description='EPEL' baseurl=http://mirrors.aliyun.com/epel/7/\$basearch/ gpgcheck=0"

# 软件包管理
ansible -i hosts all -m yum -a "name=nginx state=present"
```
