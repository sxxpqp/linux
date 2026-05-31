cmd 和 ENTRYPOINT 使用
Dockerfile

FROM alpine
CMD ["echo", "Hello from CMD"]
ENTRYPOINT ["echo", "Hello from ENTRYPOINT"]
如果您运行docker run my-image，输出将是：

Hello from ENTRYPOINT Hello from CMD
如果您运行docker run my-image "Docker", 输出将是：

Hello from ENTRYPOINT Docker
在这个例子中，CMD被用作指定默认参数，而ENTRYPOINT则指定了始终执行的命令。

start /w "" "Docker Desktop Installer.exe" install --backend=wsl-2 --installation-dir=f:\software\docker\docker --wsl-default-data-root=f:\software\wsl --accept-license