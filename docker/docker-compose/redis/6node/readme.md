docker exec -it redis-1 redis-cli -a 1 --cluster create \
172.16.150.128:6371 172.16.150.128:6372 172.16.150.128:6373 \
172.16.150.128:6374 172.16.150.128:6375 172.16.150.128:6376 \
--cluster-replicas 1

访问
docker exec -it redis-1 redis-cli -c -p 6371

cluster nodes