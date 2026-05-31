```
curl -fsSL https://chfs.sxxpqp.top:8443/chfs/shared/docker/nvidia/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \

  && curl -s -L https://chfs.sxxpqp.top:8443/chfs/shared/docker/nvidia/nvidia-container-toolkit.list -o /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install nvidia-container-toolkit
```

