# 定义变量
IMAGE_NAME := ubuntu# 镜像名称
CONTAINER_NAME := systemd# 容器名称
TAG := systemd# 镜像标签
SPORT := 22# s容器端口
DPORT := 3322# D容器端口
SRC_DIR := .# 源码目录

# ----------------------
# 构建镜像
# ----------------------
build:
	@echo "正在构建 Docker 镜像..."
	docker build  --no-cache  -t $(IMAGE_NAME):$(TAG) $(SRC_DIR)
	@echo "镜像构建完成: $(IMAGE_NAME):$(TAG)"

# ----------------------
# 启动容器
# ----------------------
start: stop
	@echo "正在启动容器 $(CONTAINER_NAME)..."
	docker run -d --privileged --name $(CONTAINER_NAME) \
	-p $(DPORT):$(SPORT) \
	-v $(SRC_DIR):/app \
	--restart always \
	$(IMAGE_NAME):$(TAG)
	@echo "容器已启动: $(CONTAINER_NAME)"

# ----------------------
# 重启容器
# ----------------------
restart: stop start
	@echo "容器 $(CONTAINER_NAME) 已重启"

# ----------------------
# 停止容器
# ----------------------
stop:
	@if [ $$(docker ps -aq --filter name=$(CONTAINER_NAME)) ]; then \
		echo "正在停止容器 $(CONTAINER_NAME)..." ; \
		docker stop $(CONTAINER_NAME); \
		docker rm $(CONTAINER_NAME); \
		echo "容器已停止并删除: $(CONTAINER_NAME)"; \
	else \
		echo "容器 $(CONTAINER_NAME) 未运行"; \
	fi

# ----------------------
# 清理镜像
# ----------------------
clean:
	@echo "正在清理镜像 $(IMAGE_NAME):$(TAG)..."
	docker rmi -f $(IMAGE_NAME):$(TAG)
	@echo "镜像已清理"

# ----------------------
# 查看日志
# ----------------------
logs:
	docker logs -f $(CONTAINER_NAME)
exec:
	docker exec -it $(CONTAINER_NAME)	 bash
