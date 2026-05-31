```
curl -fsSL https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/main/docker/nvidia/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \

  && curl -s -L https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/main/docker/nvidia/nvidia-container-toolkit.list -o /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install nvidia-container-toolkit
```

