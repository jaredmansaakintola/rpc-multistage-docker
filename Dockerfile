FROM php:7-alpine AS composer

RUN apk add --no-cache --virtual .composer-rundeps git subversion openssh-client mercurial tini bash patch make zip unzip coreutils \
 && apk add --no-cache --virtual .build-deps zlib-dev libzip-dev \
 && docker-php-ext-configure zip --with-libzip \
 && docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) zip opcache \
 && runDeps="$( \
    scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
      | tr ',' '\n' \
      | sort -u \
      | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )" \
 && apk add --no-cache --virtual .composer-phpext-rundeps $runDeps \
 && apk del .build-deps \
 && printf "# composer php cli ini settings\n\
date.timezone=UTC\n\
memory_limit=-1\n\
opcache.enable_cli=1\n\
" > $PHP_INI_DIR/php-cli.ini

ENV COMPOSER_ALLOW_SUPERUSER 1
ENV COMPOSER_HOME /tmp
ENV COMPOSER_VERSION 1.8.6

RUN curl --silent --fail --location --retry 3 --output /tmp/installer.php --url https://raw.githubusercontent.com/composer/getcomposer.org/cb19f2aa3aeaa2006c0cd69a7ef011eb31463067/web/installer \
 && php -r " \
    \$signature = '48e3236262b34d30969dca3c37281b3b4bbe3221bda826ac6a9a62d6444cdb0dcd0615698a5cbe587c3f0fe57a54d8f5'; \
    \$hash = hash('sha384', file_get_contents('/tmp/installer.php')); \
    if (!hash_equals(\$signature, \$hash)) { \
      unlink('/tmp/installer.php'); \
      echo 'Integrity check failed, installer is either corrupt or worse.' . PHP_EOL; \
      exit(1); \
    }" \
 && php /tmp/installer.php --no-ansi --install-dir=/usr/bin --filename=composer --version=${COMPOSER_VERSION} \
 && composer --ansi --version --no-interaction \
 && rm -f /tmp/installer.php \
 && find /tmp -type d -exec chmod -v 1777 {} +

WORKDIR /app

CMD ["composer"]


FROM php AS composer-install

COPY ./rpc-service /rpc
WORKDIR /rpc
COPY --from=composer /usr/bin/composer /usr/bin/composer
RUN composer install --no-dev --no-interaction -o


FROM ubuntu:16.04

ENV THRIFT_VERSION 0.9.3
ARG DEBIAN_FRONTEND=noninteractive

# copy the rpc directory
COPY ./.ssh /root/.ssh

# install ssh
RUN  apt-get -yq update

# base installs for the library
RUN apt-get update && apt-get install -y \
    build-essential \
    gcc \
    curl \
    wget \
    vim \
    make

# required python install for thrift to work alongside python
RUN apt-get install build-essential checkinstall -y \
    && apt-get install libreadline-gplv2-dev libncursesw5-dev libssl-dev libsqlite3-dev tk-dev libgdbm-dev libc6-dev libbz2-dev -y \
    && cd /usr/src \
    && wget https://www.python.org/ftp/python/2.7.12/Python-2.7.12.tgz \
    && tar xzf Python-2.7.12.tgz \
    && cd Python-2.7.12 \
    && ./configure --enable-optimizations \
    && make altinstall

# base thrift install
RUN buildDeps=" \
		automake \
		bison \
		curl \
		flex \
		g++ \
		libboost-dev \
		libboost-filesystem-dev \
		libboost-program-options-dev \
		libboost-system-dev \
		libboost-test-dev \
		libevent-dev \
		libssl-dev \
		libtool \
		make \
		pkg-config \
	"; \
	apt-get update && apt-get install -y --no-install-recommends $buildDeps && rm -rf /var/lib/apt/lists/* \
	&& curl -sSL "http://apache.mirrors.spacedump.net/thrift/$THRIFT_VERSION/thrift-$THRIFT_VERSION.tar.gz" -o thrift.tar.gz \
	&& mkdir -p /usr/src/thrift \
	&& tar zxf thrift.tar.gz -C /usr/src/thrift --strip-components=1 \
	&& rm thrift.tar.gz \
	&& cd /usr/src/thrift \
	&& ./configure  --without-python --without-cpp \
	&& make \
	&& make install \
	&& cd / \
	#&& rm -rf /usr/src/thrift \
	&& curl -k -sSL "https://storage.googleapis.com/golang/go1.4.linux-amd64.tar.gz" -o go.tar.gz \
	&& tar xzf go.tar.gz \
	&& rm go.tar.gz \
	&& cp go/bin/gofmt /usr/bin/gofmt \
	&& rm -rf go \
	&& apt-get purge -y --auto-remove $buildDeps
	
# complete thrift install using setup script
RUN cd /usr/src/thrift/lib/py/ && /usr/local/bin/python2.7 setup.py install 

# python properties needed for below
RUN apt-get update && \
    apt-get install -y software-properties-common python-software-properties 

# php libraries for composer

# instal requirements for the given repo (expects requirements to be defined in the repo)
# need to make this more configurable via a conditional with passed build arg for python or node or whatever thrift connection
RUN apt-get install -y aptitude
RUN apt-get install -y libmysqlclient-dev python-mysqldb libmagickwand-dev
RUN aptitude install -y python-dev cython libavcodec-dev libavformat-dev libswscale-dev python-pip
RUN export PATH=$PATH:/usr/local/mysql/bin/

COPY --from=composer-install /rpc /rpc
WORKDIR /rpc
#COPY --from=composer /usr/bin/composer /usr/bin/composer

#RUN composer install --no-dev --no-interaction -o
RUN pip install -r requirements.txt && \
    pip install ffvideo

VOLUME /rpc

CMD tail -f /dev/null
