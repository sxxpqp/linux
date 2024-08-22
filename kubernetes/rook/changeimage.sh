#!/bin/bash
for i in `cat docker-images.txt`
do
#  含docker.io的镜像 docker pull docker tag docker push

# 修改为iharbor.sxxpqp.top仓库
if [[ ! $i =~ "/" ]]; then
  echo "不含"/"的镜像：${i}"
  docker pull ${i}
  docker tag ${i} iharbor.sxxpqp.top/library/${i}
  docker push iharbor.sxxpqp.top/library/${i}


elif  [[ $i =~ "docker.io" ]]; then
  echo "含docker.io的镜像：${i}"
  docker pull ${i}
  docker tag ${i} ${i//docker.io/iharbor.sxxpqp.top}
  docker push ${i//docker.io/iharbor.sxxpqp.top}

  docker push iharbor.sxxpqp.top/${i}
# 不含"/" 如nginx

else
# 含"/" 如k8s.gcr.io/rook/ceph:v1.7.4
  echo "含"/"的其他镜像：${i}"
  docker pull ${i}
  docker tag ${i} iharbor.sxxpqp.top/${i}
  docker push iharbor.sxxpqp.top/${i}
fi
done