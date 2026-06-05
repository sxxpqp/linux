# NVIDIA Device Plugin 测试 — GPU Pod + 容器运行时配置

> 源: https://github.com/sxxpqp/linux/blob/main/kubernetes/kube-device-plugin/readme.md
> 状态: 验证过

K8s 调度 GPU Pod 的最小验证脚本,以及配套 `nvidia-ctk` 让 docker / containerd 支持 NVIDIA runtime。

前置:节点已装 NVIDIA Driver + `nvidia-container-toolkit`,K8s 已部署 `nvidia-device-plugin` DaemonSet。

## 1. 跑一个测试 GPU Pod

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  restartPolicy: Never
  containers:
    - name: cuda-container
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
      resources:
        limits:
          nvidia.com/gpu: 1   # 申请 1 块 GPU
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
EOF
```

## 2. 验证输出

```bash
kubectl logs gpu-pod
```

期望:

```
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

## 3. 容器运行时配 NVIDIA(节点上)

### Docker

```bash
nvidia-ctk runtime configure --runtime=docker --config=$HOME/.config/docker/daemon.json
sudo systemctl restart docker
```

### containerd

```bash
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd
```

> 完整 NVIDIA Container Toolkit 安装见 [../../ai/nvidia-container-toolkit/README.md](../../ai/nvidia-container-toolkit/README.md)。
