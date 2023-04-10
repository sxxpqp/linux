### 安装nvidia-docker2 //需要跟docker版本对应 离线请自行goolge搜索
```bash
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list
sudo apt-get update && sudo apt-get install -y nvidia-docker2
sudo pkill -SIGHUP dockerd
```

### 配置/etc/docker/daemon.json
```json
{
    "runtimes": {
        "nvidia": {
        "path": "/usr/bin/nvidia-container-runtime",
        "runtimeArgs": []
        }
    },
    "default-runtime": "nvidia"
}
```
### 重启docker
```bash
sudo systemctl daemon-reload
sudo systemctl restart docker
```
### 测试
```bash
docker run --runtime=nvidia --rm nvidia/cuda nvidia-smi //或者不需要--runtime=nvidia
```
安装k8s-nvidia-device-plugin
```bash
kubectl create -f https://github.com/NVIDIA/k8s-device-plugin/blob/main/nvidia-device-plugin.yml
```