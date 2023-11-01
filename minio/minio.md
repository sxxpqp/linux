#在mc容器中配置config.json
```
mc config host add minio1 http://minio1:9000 minio minio123
mc config host add minio2 http://minio2:9000 minio minio123
```

#minio 通过mc实现备份  minio1 -> minio2
mc mirror --watch --overwrite --remove --ignore-existing minio1 minio2
#minio 通过mc实现备份 minio2 -> minio1
mc mirror --watch --overwrite --remove --ignore-existing minio2 minio1
