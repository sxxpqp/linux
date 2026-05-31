
#isntall nvidia-docker
```
sudo dpkg -i *.deb
```
###The nvidia-ctk command modifies the /etc/docker/daemon.json file on the host. The file is updated so that Docker can use the NVIDIA Container Runtime.
```
sudo nvidia-ctk runtime configure --runtime=docker
```

```
sudo systemctl restart docker
```


###The nvidia-ctk command modifies the /etc/containerd/config.toml file on the host. The file is updated so that containerd can use the NVIDIA Container Runtime.
sudo nvidia-ctk runtime configure --runtime=containerd