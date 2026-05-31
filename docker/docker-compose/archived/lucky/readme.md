#接口地址
https://oapi.dingtalk.com/robot/send?access_token=f7e3042940f7edb987f7df8513742ba5b5ca28b8112c8655759993c18bd17a8c


#请求方法
POST
#请求头
Content-Type: application/json

# 请求体
{
  "msgtype": "text",
  "text": {
    "content": "现在时间: {time} 规则名称: {ruleName}  ip+port: {ipAddr}"
    
  }
}