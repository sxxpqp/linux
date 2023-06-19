```
docker run --privileged -d --net=host  --name=clash dockerproxy.com/sxxpqp/clash:v1
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
curl -I https://google.com
```

