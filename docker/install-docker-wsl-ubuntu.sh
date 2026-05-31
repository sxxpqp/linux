# install docker
curl -fsSL https://chfs.sxxpqp.top:8443/chfs/shared/docker/install-docker.sh -o get-docker.sh
sh get-docker.sh

if [ ! $(getent group docker) ];
then 
    sudo groupadd docker;
else
    echo "docker user group already exists"
fi

sudo gpasswd -a $USER docker
sudo service docker restart

rm -rf get-docker.sh