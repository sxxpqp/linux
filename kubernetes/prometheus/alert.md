global:
  resolve_timeout: 3m

route:
  # 修改：加入了 instance 分组
  group_by: ['instance', 'namespace']
  # 修改：按你要求设为 10m（注意：这会导致首条告警延迟10分钟发出）
  group_wait: 30s
  # 修改：按你要求设为 10s
  group_interval: 5m
  # 修改：按你要求设为 10m
  repeat_interval: 1h
  # 修改：默认接收器改为钉钉 Webhook
  receiver: 'web.hook.prometheusalert'
  routes:
  - receiver: 'Watchdog'
    matchers:
    - alertname="Watchdog"
  - receiver: "null"
    matchers:
    - alertname="InfoInhibitor"
  - receiver: 'web.hook.prometheusalert'
    matchers:
    - severity="critical"

inhibit_rules:
- source_matchers:
  - severity="critical"
  target_matchers:
  - severity=~"warning|info"
  equal:
  - namespace
  - alertname
- source_matchers:
  - severity="warning"
  target_matchers:
  - severity="info"
  equal:
  - namespace
  - alertname
- source_matchers:
  - alertname="InfoInhibitor"
  target_matchers:
  - severity="info"
  equal:
  - namespace

receivers:
- name: 'Default'
- name: 'Watchdog'
- name: 'Critical'
- name: 'null'
# 新增：PrometheusAlert 接收器
- name: 'web.hook.prometheusalert'
  webhook_configs:
  - url: 'http://prometheus-alert-center:8080/prometheusalert?type=wx&tpl=prometheus-wx&wxurl=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=6dd8d89f-a0a0-47e1-9992-81c16ab11582&at=舒鑫鑫'



# kubectl -n monitoring edit secret alertmanager-main 直接修改
  
  # base64
 
Z2xvYmFsOgogIHJlc29sdmVfdGltZW91dDogM20KCnJvdXRlOgogICMg5L+u5pS577ya5Yqg5YWl5LqGIGluc3RhbmNlIOWIhue7hAogIGdyb3VwX2J5OiBbJ2luc3RhbmNlJywgJ25hbWVzcGFjZSddCiAgIyDkv67mlLnvvJrmjInkvaDopoHmsYLorr7kuLogMTBt77yI5rOo5oSP77ya6L+Z5Lya5a+86Ie06aaW5p2h5ZGK6K2m5bu26L+fMTDliIbpkp/lj5Hlh7rvvIkKICBncm91cF93YWl0OiAzMHMKICAjIOS/ruaUue+8muaMieS9oOimgeaxguiuvuS4uiAxMHMKICBncm91cF9pbnRlcnZhbDogNW0KICAjIOS/ruaUue+8muaMieS9oOimgeaxguiuvuS4uiAxMG0KICByZXBlYXRfaW50ZXJ2YWw6IDFoCiAgIyDkv67mlLnvvJrpu5jorqTmjqXmlLblmajmlLnkuLrpkonpkokgV2ViaG9vawogIHJlY2VpdmVyOiAnd2ViLmhvb2sucHJvbWV0aGV1c2FsZXJ0JwogIHJvdXRlczoKICAtIHJlY2VpdmVyOiAnV2F0Y2hkb2cnCiAgICBtYXRjaGVyczoKICAgIC0gYWxlcnRuYW1lPSJXYXRjaGRvZyIKICAtIHJlY2VpdmVyOiAibnVsbCIKICAgIG1hdGNoZXJzOgogICAgLSBhbGVydG5hbWU9IkluZm9JbmhpYml0b3IiCiAgLSByZWNlaXZlcjogJ3dlYi5ob29rLnByb21ldGhldXNhbGVydCcKICAgIG1hdGNoZXJzOgogICAgLSBzZXZlcml0eT0iY3JpdGljYWwiCgppbmhpYml0X3J1bGVzOgotIHNvdXJjZV9tYXRjaGVyczoKICAtIHNldmVyaXR5PSJjcml0aWNhbCIKICB0YXJnZXRfbWF0Y2hlcnM6CiAgLSBzZXZlcml0eT1+Indhcm5pbmd8aW5mbyIKICBlcXVhbDoKICAtIG5hbWVzcGFjZQogIC0gYWxlcnRuYW1lCi0gc291cmNlX21hdGNoZXJzOgogIC0gc2V2ZXJpdHk9Indhcm5pbmciCiAgdGFyZ2V0X21hdGNoZXJzOgogIC0gc2V2ZXJpdHk9ImluZm8iCiAgZXF1YWw6CiAgLSBuYW1lc3BhY2UKICAtIGFsZXJ0bmFtZQotIHNvdXJjZV9tYXRjaGVyczoKICAtIGFsZXJ0bmFtZT0iSW5mb0luaGliaXRvciIKICB0YXJnZXRfbWF0Y2hlcnM6CiAgLSBzZXZlcml0eT0iaW5mbyIKICBlcXVhbDoKICAtIG5hbWVzcGFjZQoKcmVjZWl2ZXJzOgotIG5hbWU6ICdEZWZhdWx0JwotIG5hbWU6ICdXYXRjaGRvZycKLSBuYW1lOiAnQ3JpdGljYWwnCi0gbmFtZTogJ251bGwnCiMg5paw5aKe77yaUHJvbWV0aGV1c0FsZXJ0IOaOpeaUtuWZqAotIG5hbWU6ICd3ZWIuaG9vay5wcm9tZXRoZXVzYWxlcnQnCiAgd2ViaG9va19jb25maWdzOgogIC0gdXJsOiAnaHR0cDovL3Byb21ldGhldXMtYWxlcnQtY2VudGVyOjgwODAvcHJvbWV0aGV1c2FsZXJ0P3R5cGU9d3gmdHBsPXByb21ldGhldXMtd3gmd3h1cmw9aHR0cHM6Ly9xeWFwaS53ZWl4aW4ucXEuY29tL2NnaS1iaW4vd2ViaG9vay9zZW5kP2tleT02ZGQ4ZDg5Zi1hMGEwLTQ3ZTEtOTk5Mi04MWMxNmFiMTE1ODImYXQ96IiS6ZGr6ZGrJw==

