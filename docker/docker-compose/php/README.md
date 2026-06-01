# php

PHP-FPM + Nginx 经典开发组合,**镜像版本明显过气**:

| 服务 | 镜像 | 上游状态 |
|---|---|---|
| php | `sxxpqp/php-fpm:5.6` | PHP 5.6 已 EOL 多年 (2019-01) |
| nginx | `nginx:1.13` | 已停止维护 (2017) |

## ⚠ 状态待确认

这套配置应该是**老业务遗留**(只能跑 PHP 5.6 代码的客户/项目)。

下次到现场确认:
- 还在跑某个老业务 → 留着,补一段"跑在哪台 / 给哪个项目用"
- 已下线 → `git mv php archived/php`

## 如果只是新写代码

不要用这套。新项目用:
- PHP 8.x:`dockerhub.ihome.sxxpqp.top:8443/library/php:8.3-fpm-alpine`
- Nginx 主线:`dockerhub.ihome.sxxpqp.top:8443/library/nginx:alpine`
