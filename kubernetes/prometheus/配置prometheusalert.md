{{- $var := .externalURL -}}
{{- range $k,$v:=.alerts -}}
{{- if eq $v.status "resolved" -}}
[PROMETHEUS-恢复信息-测试线]({{$v.generatorURL}})
> <font color="info">**{{$v.labels.alertname}}**</font>
> <font color="info">告警级别：</font>{{$v.labels.level}}
> <font color="info">开始时间：</font>{{GetCSTtime $v.startsAt}}
> <font color="info">结束时间：</font>{{GetCSTtime $v.endsAt}}
> <font color="info">故障主机IP：</font>{{$v.labels.instance}}
> <font color="info">**{{$v.annotations.description}}**</font>
{{- else -}}
[PROMETHEUS-告警信息-测试线]({{$v.generatorURL}})
> <font color="warning">**{{$v.labels.alertname}}**</font>
> <font color="warning">告警级别：</font>{{$v.labels.level}}
> <font color="warning">开始时间：</font>{{GetCSTtime $v.startsAt}}
> <font color="warning">故障主机IP：</font>{{$v.labels.instance}}
> <font color="warning">当前时间：</font>{{GetCSTtime ""}}
> <font color="warning">**{{$v.annotations.description}}**</font>
{{- end -}}
{{- end -}}
{{- $urimsg:="" -}}
{{- range $key,$value:=.commonLabels -}}
{{- $urimsg = print $urimsg $key "%3D%22" $value "%22%2C" -}}
{{- end -}}






alertmanager.yaml: Imdsb2JhbCI6CiAgInJlc29sdmVfdGltZW91dCI6ICI1bSIKImluaGliaXRfcnVsZXMiOgotICJlcXVhbCI6CiAgLSAibmFtZXNwYWNlIgogIC0gImFsZXJ0bmFtZSIKICAic291cmNlX21hdGNoZXJzIjoKICAtICJzZXZlcml0eSA9IGNyaXRpY2FsIgogICJ0YXJnZXRfbWF0Y2hlcnMiOgogIC0gInNldmVyaXR5ID1+IHdhcm5pbmd8aW5mbyIKLSAiZXF1YWwiOgogIC0gIm5hbWVzcGFjZSIKICAtICJhbGVydG5hbWUiCiAgInNvdXJjZV9tYXRjaGVycyI6CiAgLSAic2V2ZXJpdHkgPSB3YXJuaW5nIgogICJ0YXJnZXRfbWF0Y2hlcnMiOgogIC0gInNldmVyaXR5ID0gaW5mbyIKLSAiZXF1YWwiOgogIC0gIm5hbWVzcGFjZSIKICAic291cmNlX21hdGNoZXJzIjoKICAtICJhbGVydG5hbWUgPSBJbmZvSW5oaWJpdG9yIgogICJ0YXJnZXRfbWF0Y2hlcnMiOgogIC0gInNldmVyaXR5ID0gaW5mbyIKInJlY2VpdmVycyI6Ci0gIm5hbWUiOiAiRGVmYXVsdCIKLSAibmFtZSI6ICJXYXRjaGRvZyIKLSAibmFtZSI6ICJDcml0aWNhbCIKLSAibmFtZSI6ICJudWxsIgoicm91dGUiOgogICJncm91cF9ieSI6CiAgLSAibmFtZXNwYWNlIgogICJncm91cF9pbnRlcnZhbCI6ICI1bSIKICAiZ3JvdXBfd2FpdCI6ICIzMHMiCiAgInJlY2VpdmVyIjogIkRlZmF1bHQiCiAgInJlcGVhdF9pbnRlcnZhbCI6ICIxMmgiCiAgInJvdXRlcyI6CiAgLSAibWF0Y2hlcnMiOgogICAgLSAiYWxlcnRuYW1lID0gV2F0Y2hkb2ciCiAgICAicmVjZWl2ZXIiOiAiV2F0Y2hkb2ciCiAgLSAibWF0Y2hlcnMiOgogICAgLSAiYWxlcnRuYW1lID0gSW5mb0luaGliaXRvciIKICAgICJyZWNlaXZlciI6ICJudWxsIgogIC0gIm1hdGNoZXJzIjoKICAgIC0gInNldmVyaXR5ID0gY3JpdGljYWwiCiAgICAicmVjZWl2ZXIiOiAiQ3JpdGljYWwi




"global":
  "resolve_timeout": "5m"
"inhibit_rules":
- "equal":
  - "namespace"
  - "alertname"
  "source_matchers":
  - "severity = critical"
  "target_matchers":
  - "severity =~ warning|info"
- "equal":
  - "namespace"
  - "alertname"
  "source_matchers":
  - "severity = warning"
  "target_matchers":
  - "severity = info"
- "equal":
  - "namespace"
  "source_matchers":
  - "alertname = InfoInhibitor"
  "target_matchers":
  - "severity = info"
"receivers":
- "name": "Default"
- "name": "Watchdog"
- "name": "Critical"
- "name": "null"
"route":
  "group_by":
  - "namespace"
  "group_interval": "5m"
  "group_wait": "30s"
  "receiver": "Default"
  "repeat_interval": "12h"
  "routes":
  - "matchers":
    - "alertname = Watchdog"
    "receiver": "Watchdog"
  - "matchers":
    - "alertname = InfoInhibitor"
    "receiver": "null"
  - "matchers":
    - "severity = critical"
    "receiver": "Critical"






global:
  resolve_timeout: 5m

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




https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=6dd8d89f-a0a0-47e1-9992-81c16ab11582




{
	"receiver": "prometheus-alert-center",
	"status": "firing",
	"alerts": [{
		"status": "firing",
		"labels": {
			"alertname": "TargetDown",
			"index": "1",
			"instance": "example-1",
			"job": "example",
			"level": "2",
			"service": "example"
		},
		"annotations": {
			"description": "target was down! example dev /example-1 was down for more than 120s.",
			"level": "2",
			"timestamp": "2020-05-21 02:58:07.829 +0000 UTC"
		},
		"startsAt": "2020-05-21T02:58:07.830216179Z",
		"endsAt": "0001-01-01T00:00:00Z",
		"generatorURL": "https://prometheus-alert-center/graph?g0.expr=up%7Bjob%21%3D%22kubernetes-pods%22%2Cjob%21%3D%22kubernetes-service-endpoints%22%7D+%21%3D+1\u0026g0.tab=1",
		"fingerprint": "e2a5025853d4da64"
	}],
	"groupLabels": {
		"instance": "example-1"
	},
	"commonLabels": {
		"alertname": "TargetDown",
		"index": "1",
		"instance": "example-1",
		"job": "example",
		"level": "2",
		"service": "example"
	},
	"commonAnnotations": {
		"description": "target was down! example dev /example-1 was down for more than 120s.",
		"level": "2",
		"timestamp": "2020-05-21 02:58:07.829 +0000 UTC"
	},
	"externalURL": "https://prometheus-alert-center",
	"version": "4",
	"groupKey": "{}/{job=~\"^(?:.*)$\"}:{instance=\"example-1\"}"
}


