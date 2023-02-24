# FROM alpine:latest
# ENV PATH=/usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ENV LANG=C.UTF-8
# RUN apk add --no-cache ca-certificates
# ENV GPG_KEY=0D96DF4D4110E5C43FBFB17F2D347EA6AA65421D
# ENV PYTHON_VERSION=3.6.6

# RUN set -ex && apk add --no-cache --virtual .fetch-deps gnupg libressl tar xz && wget -O python.tar.xz "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz" && wget -O python.tar.xz.asc "https://www.python.org/ftp/python/${PYTHON_VERSION%%[a-z]*}/Python-$PYTHON_VERSION.tar.xz.asc" && export GNUPGHOME="$(mktemp -d)" && gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "$GPG_KEY" && gpg --batch --verify python.tar.xz.asc python.tar.xz && rm -rf "$GNUPGHOME" python.tar.xz.asc && mkdir -p /usr/src/python && tar -xJC /usr/src/python --strip-components=1 -f python.tar.xz && rm python.tar.xz && apk add --no-cache --virtual .build-deps bzip2-dev coreutils dpkg-dev dpkg expat-dev gcc gdbm-dev libc-dev libffi-dev libressl libressl-dev linux-headers make ncurses-dev pax-utils readline-dev sqlite-dev tcl-dev tk tk-dev xz-dev zlib-dev && apk del .fetch-deps && cd /usr/src/python && gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" && ./configure --build="$gnuArch" --enable-loadable-sqlite-extensions --enable-shared --with-system-expat --with-system-ffi --without-ensurepip && make -j "$(nproc)" EXTRA_CFLAGS="-DTHREAD_STACK_SIZE=0x100000" && make install && runDeps="$( scanelf --needed --nobanner --format '%n#p' --recursive /usr/local | tr ',' '\n' | sort -u | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' )" && apk add --virtual .python-rundeps $runDeps && apk del .build-deps && find /usr/local -depth \( \( -type d -a \( -name test -o -name tests \) \) -o \( -type f -a \( -name '*.pyc' -o -name '*.pyo' \) \) \) -exec rm -rf '{}' + && rm -rf /usr/src/python
# RUN cd /usr/local/bin && ln -s idle3 idle && ln -s pydoc3 pydoc && ln -s python3 python && ln -s python3-config python-config
# ENV PYTHON_PIP_VERSION=10.0.1
# RUN set -ex; apk add --no-cache --virtual .fetch-deps libressl; wget -O get-pip.py 'https://bootstrap.pypa.io/get-pip.py'; apk del .fetch-deps; python get-pip.py --disable-pip-version-check --no-cache-dir "pip==$PYTHON_PIP_VERSION" ; pip --version; find /usr/local -depth \( \( -type d -a \( -name test -o -name tests \) \) -o \( -type f -a \( -name '*.pyc' -o -name '*.pyo' \) \) \) -exec rm -rf '{}' +; rm -f get-pip.py
# CMD ["python3"]
# COPY . /code
# WORKDIR /code
# RUN pip install -i https://pypi.doubanio.com/simple/ -r requirements.txt
# CMD ["python" "sql_import.py"]
# FROM harbor.iot.store:8085/turing-kubesphere/init-sql-import:app
# RUN rm -rf /code/sql_dir /code/turing
# COPY turing /code/turing
# COPY sql_dir /code/sql_dir
# FROM golang:alpine as builder

# WORKDIR /go/src/github.com/flipped-aurora/gin-vue-admin/server
# COPY . .

# RUN go env -w GO111MODULE=on \
#     && go env -w GOPROXY=https://goproxy.cn,direct \
#     && go env -w CGO_ENABLED=0 \
#     && go env \
#     && go mod tidy \
#     && go build -o server .

# FROM alpine:latest

# LABEL MAINTAINER="SliverHorn@sliver_horn@qq.com"

# WORKDIR /go/src/github.com/flipped-aurora/gin-vue-admin/server

# COPY --from=0 /go/src/github.com/flipped-aurora/gin-vue-admin/server/server ./
# COPY --from=0 /go/src/github.com/flipped-aurora/gin-vue-admin/server/resource ./resource/
# COPY --from=0 /go/src/github.com/flipped-aurora/gin-vue-admin/server/config.docker.yaml ./

# EXPOSE 8888
# ENTRYPOINT ./server -c config.docker.yaml
FROM mysql:5.7
WORKDIR /opt
COPY . .
RUN chmod +x ./mc
RUN mv ./mc /usr/local/bin/
CMD [ "bash" ,"init.sh" ]

