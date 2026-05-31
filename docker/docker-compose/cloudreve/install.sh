#!/bin/sh
# 函数：检查并创建目录
check_and_create_dir() {
  local dir_path="$1"
  if [ -d "$dir_path" ]; then
    echo "directory \"$dir_path\" exists"
  else
    mkdir -p "$dir_path"
    echo "directory \"$dir_path\" created"
  fi
}

# 函数：检查并创建文件
check_and_create_file() {
  local file_path="$1"
  if [ -f "$file_path" ]; then
    echo "file \"$file_path\" exists"
  else
    touch "$file_path"
    echo "file \"$file_path\" created"
  fi
}
#获取当前路径 
echo "current path is $(pwd)"

#判断文件是否存在
if [ -d "$(pwd)/cloudreve" ]; then
   cd $(pwd)/cloudreve
else
 mkdir $(pwd)/cloudreve
 cd $(pwd)/cloudreve
fi
# 下载文件通过curl
curl https://chfs.sxxpqp.top:8443/chfs/shared/docker/docker-compose/cloudreve/docker-compose.yml -o docker-compose.yml
# 执行docker-compose
if [ -d "$PWD/data" ]; then
   echo "directory \"mkdir -p $PWD/data\" exists"
else
   mkdir -p $PWD/data
   echo "directory \"mkdir -p $PWD/data\" created"
fi
# 检查并创建所有需要的目录
check_and_create_dir "$PWD/cloudreve/uploads"
check_and_create_dir "$PWD/cloudreve/avatar"
check_and_create_dir "$PWD/aria2/config"

# 检查并创建所有需要的文件
check_and_create_file "$PWD/cloudreve/conf.ini"
check_and_create_file "$PWD/cloudreve/cloudreve.db"
docker-compose up -d