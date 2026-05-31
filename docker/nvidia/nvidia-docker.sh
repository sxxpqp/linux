#!/bin/bash

#NVIDIA_DOCKER_URL="https://mirror.cs.uchicago.edu/nvidia-docker/libnvidia-container/stable/ubuntu20.04/amd64/"
#!/bin/bash

# 定义支持的 Ubuntu 版本（可根据实际需求增删）
SUPPORTED_VERSIONS=("18.04" "20.04.6" "22.04.5" "24.04.2")

# 提示用户选择系统版本
echo "请选择你的 Ubuntu 版本（支持：${SUPPORTED_VERSIONS[*]}）："
read -p "输入版本号（如 20.04.6）: " UBUNTU_VERSION

# 验证输入的版本是否支持
if [[ ! " ${SUPPORTED_VERSIONS[@]} " =~ " ${UBUNTU_VERSION} " ]]; then
    echo "错误：不支持的版本 ${UBUNTU_VERSION}，支持的版本为 ${SUPPORTED_VERSIONS[*]}"
    exit 1
fi

# 定义下载链接和本地文件名（包含版本号）
LIST_URL="https://chfs.sxxpqp.top:8443/chfs/shared/docker/nvidia/nvidia-docker-ubuntu${UBUNTU_VERSION}.tar.gz"
LIST_PATH="nvidia-docker-ubuntu${UBUNTU_VERSION}.tar.gz"

# 下载离线包
echo "开始下载适用于 Ubuntu ${UBUNTU_VERSION} 的 nvidia-docker 离线包..."
curl -s -L "$LIST_URL" -o "$LIST_PATH"

# 检查下载是否成功
if [ $? -ne 0 ]; then
    echo "错误：下载失败，请检查链接是否有效或网络是否通畅"
    exit 1
fi

# 解压离线包
echo "解压离线包..."
tar -zxvf "$LIST_PATH"

# 进入包目录并安装
echo "开始安装 nvidia-container-toolkit 及其依赖..."
cd "nvidia-packages" || {
    echo "错误：解压后未找到 nvidia-packages 目录"
    exit 1
}

# 安装所有 .deb 包
sudo dpkg -i *.deb

# 修复可能的依赖问题（离线环境下若有基础依赖缺失需提前处理）
sudo apt-get -f install -y

# 验证安装
if command -v nvidia-ctk &> /dev/null; then
    echo "NVIDIA_CONTAINER 部署完成！版本信息："
    nvidia-ctk --version
else
    echo "警告：部署完成，但未检测到 nvidia-ctk 命令，可能安装存在问题"
fi

# Optional: Ensure dependencies are resolved after installation
# apt-get install -f



# 测试
# xhost+
 
# sudo nvidia-docker run --rm -it -e DISPLAY=$DISPLAY -e GDK_SCALE -e GDK_DPI_SCAL -v /tmp/.X11-unix:/tmp/.X11-unix registry.cn-hangzhou.aliyuncs.com/sxxpqp/cuda:11.0-base
# or
# sudo docker run --rm --runtime=nvidia -it -e DISPLAY=$DISPLAY -e GDK_SCALE -e GDK_DPI_SCAL -v /tmp/.X11-unix:/tmp/.X11-unix registry.cn-hangzhou.aliyuncs.com/sxxpqp/cuda:11.0-base