# Ansible 自动化

Ansible 自动化配置管理与 ad-hoc 命令示例。

## 文件说明

| 文件 | 说明 |
|---|---|
| [centos.yaml](centos.yaml) | CentOS 系统初始化 Playbook |
| [hello_world.yml](hello_world.yml) | Ansible Hello World 示例 Playbook |
| [hosts](hosts) | Ansible Inventory 主机列表 |
| [Dockerfile](Dockerfile) | Ansible 运行环境 Docker 镜像 |
| [docker-compose.yaml](docker-compose.yaml) | Ansible Docker Compose 编排 |

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
