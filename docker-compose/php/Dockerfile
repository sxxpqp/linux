FROM php:5.6.40-fpm-jessie
# 安装swoole扩展
RUN pecl install swoole-1.10.5 && docker-php-ext-enable swoole
# 安装mysql扩展
RUN docker-php-ext-install mysqli pdo_mysql && docker-php-ext-enable mysqli pdo_mysql

# apt-get源更换
RUN mv /etc/apt/sources.list /etc/apt/sources.list.bak \
# ignored, or old ones used instead
    && echo "deb http://archive.debian.org/debian-archive/debian/ stretch main non-free contrib" >/etc/apt/sources.list \
    && echo "deb http://archive.debian.org/debian-archive/debian stretch-proposed-updates main non-free contrib" >>/etc/apt/sources.list \
    && echo "deb-src http://archive.debian.org/debian-archive/debian stretch main non-free contrib" >>/etc/apt/sources.list \
    && echo "deb-src http://archive.debian.org/debian-archive/debian stretch-proposed-updates main non-free contrib" >>/etc/apt/sources.list
# php5.6安装gd扩展开启freetye jpeg png webp 支持
RUN apt-get update && apt-get install -y  libfreetype6-dev libjpeg62-turbo-dev libpng-dev && docker-php-ext-configure gd --with-freetype-dir=/usr/include/freetype2/freetype --with-jpeg-dir=/usr/include/ && docker-php-ext-install -j$(nproc) gd && docker-php-ext-enable gd
WORKDIR  /usr/share/nginx/html/
