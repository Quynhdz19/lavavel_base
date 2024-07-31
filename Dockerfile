FROM php:8.1.13-fpm-alpine3.17


ENV LD_PRELOAD /usr/lib/preloadable_libiconv.so php
RUN apk add --no-cache --repository http://dl-3.alpinelinux.org/alpine/edge/community gnu-libiconv

### ----------------------------------------------------------
### Part 1 of Nginx Dockerfile source https://github.com/nginxinc/docker-nginx/blob/4785a604aa40e0b0a69047a61e28781a2b0c2069/stable/alpine-slim/Dockerfile
### ----------------------------------------------------------

ENV NGINX_VERSION 1.22.1
ENV PKG_RELEASE   1

RUN set -x \
# create nginx user/group first, to be consistent throughout docker variants
    && addgroup -g 101 -S nginx \
    && adduser -S -D -H -u 101 -h /var/cache/nginx -s /sbin/nologin -G nginx -g nginx nginx \
    && apkArch="$(cat /etc/apk/arch)" \
    && nginxPackages=" \
        nginx=${NGINX_VERSION}-r${PKG_RELEASE} \
    " \
# install prerequisites for public key and pkg-oss checks
    && apk add --no-cache --virtual .checksum-deps \
        openssl \
    && case "$apkArch" in \
        x86_64|aarch64) \
# arches officially built by upstream
            set -x \
            && KEY_SHA512="e09fa32f0a0eab2b879ccbbc4d0e4fb9751486eedda75e35fac65802cc9faa266425edf83e261137a2f4d16281ce2c1a5f4502930fe75154723da014214f0655" \
            && wget -O /tmp/nginx_signing.rsa.pub https://nginx.org/keys/nginx_signing.rsa.pub \
            && if echo "$KEY_SHA512 */tmp/nginx_signing.rsa.pub" | sha512sum -c -; then \
                echo "key verification succeeded!"; \
                mv /tmp/nginx_signing.rsa.pub /etc/apk/keys/; \
            else \
                echo "key verification failed!"; \
                exit 1; \
            fi \
            && apk add -X "https://nginx.org/packages/alpine/v$(egrep -o '^[0-9]+\.[0-9]+' /etc/alpine-release)/main" --no-cache $nginxPackages \
            ;; \
        *) \
# we're on an architecture upstream doesn't officially build for
# let's build binaries from the published packaging sources
            set -x \
            && tempDir="$(mktemp -d)" \
            && chown nobody:nobody $tempDir \
            && apk add --no-cache --virtual .build-deps \
                gcc \
                libc-dev \
                make \
                openssl-dev \
                pcre2-dev \
                zlib-dev \
                linux-headers \
                bash \
                alpine-sdk \
                findutils \
            && su nobody -s /bin/sh -c " \
                export HOME=${tempDir} \
                && cd ${tempDir} \
                && curl -f -O https://hg.nginx.org/pkg-oss/archive/757.tar.gz \
                && PKGOSSCHECKSUM=\"32a039e8d3cc54404a8ad4a31981e76a49632f1ebec2f45bb309689d6ba2f82e3e8aea8abf582b49931636ea53271b48a7e2f2ef8ebe35b167b3fe18b8b99852 *757.tar.gz\" \
                && if [ \"\$(openssl sha512 -r 757.tar.gz)\" = \"\$PKGOSSCHECKSUM\" ]; then \
                    echo \"pkg-oss tarball checksum verification succeeded!\"; \
                else \
                    echo \"pkg-oss tarball checksum verification failed!\"; \
                    exit 1; \
                fi \
                && tar xzvf 757.tar.gz \
                && cd pkg-oss-757 \
                && cd alpine \
                && make base \
                && apk index -o ${tempDir}/packages/alpine/${apkArch}/APKINDEX.tar.gz ${tempDir}/packages/alpine/${apkArch}/*.apk \
                && abuild-sign -k ${tempDir}/.abuild/abuild-key.rsa ${tempDir}/packages/alpine/${apkArch}/APKINDEX.tar.gz \
                " \
            && cp ${tempDir}/.abuild/abuild-key.rsa.pub /etc/apk/keys/ \
            && apk del .build-deps \
            && apk add -X ${tempDir}/packages/alpine/ --no-cache $nginxPackages \
            ;; \
    esac \
# remove checksum deps
    && apk del .checksum-deps \
# if we have leftovers from building, let's purge them (including extra, unnecessary build deps)
    && if [ -n "$tempDir" ]; then rm -rf "$tempDir"; fi \
    && if [ -n "/etc/apk/keys/abuild-key.rsa.pub" ]; then rm -f /etc/apk/keys/abuild-key.rsa.pub; fi \
    && if [ -n "/etc/apk/keys/nginx_signing.rsa.pub" ]; then rm -f /etc/apk/keys/nginx_signing.rsa.pub; fi \
# Bring in gettext so we can get `envsubst`, then throw
# the rest away. To do this, we need to install `gettext`
# then move `envsubst` out of the way so `gettext` can
# be deleted completely, then move `envsubst` back.
    && apk add --no-cache --virtual .gettext gettext \
    && mv /usr/bin/envsubst /tmp/ \
    \
    && runDeps="$( \
        scanelf --needed --nobanner /tmp/envsubst \
            | awk '{ gsub(/,/, "\nso:", $2); print "so:" $2 }' \
            | sort -u \
            | xargs -r apk info --installed \
            | sort -u \
    )" \
    && apk add --no-cache $runDeps \
    && apk del .gettext \
    && mv /tmp/envsubst /usr/local/bin/ \
# Bring in tzdata so users could set the timezones through the environment
# variables
    && apk add --no-cache tzdata \
# forward request and error logs to docker log collector
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
# create a docker-entrypoint.d directory
    && mkdir /docker-entrypoint.d

COPY .docker/nginx/scripts/docker-entrypoint.sh /
COPY .docker/nginx/scripts/10-listen-on-ipv6-by-default.sh /docker-entrypoint.d
COPY .docker/nginx/scripts/20-envsubst-on-templates.sh /docker-entrypoint.d
COPY .docker/nginx/scripts/30-tune-worker-processes.sh /docker-entrypoint.d
RUN chmod +x /docker-entrypoint.sh /docker-entrypoint.d/*.sh
ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 80

STOPSIGNAL SIGQUIT

### ----------------------------------------------------------
### Setup supervisord
### ----------------------------------------------------------

RUN set -x && \
    apk update && apk upgrade && \
    apk add --no-cache \
        supervisor \
        && \
    rm -Rf /etc/nginx/nginx.conf && \
    rm -Rf /etc/nginx/conf.d/default.conf && \
    # folders
    mkdir -p /var/log/supervisor

### ----------------------------------------------------------
### Install php dependency
### ----------------------------------------------------------

RUN apk add wget \
  curl \
  git \
  build-base \
  libmcrypt-dev \
  libxml2-dev \
  linux-headers \
  pcre-dev \
  zlib-dev \
  autoconf \
  cyrus-sasl-dev \
  libgsasl-dev \
  oniguruma-dev \
  libressl \
  libressl-dev \
  imagemagick-dev \
  imagemagick \
  libpng \
  libjpeg-turbo \
  freetype-dev \
  libpng-dev \
  libjpeg-turbo-dev \
  shadow \
  zip \
  libzip-dev \
  bash

RUN pecl install imagick && docker-php-ext-enable imagick && docker-php-ext-install gd && docker-php-ext-configure gd

RUN docker-php-ext-configure zip && docker-php-ext-install zip

RUN pecl channel-update pecl.php.net; \
  docker-php-ext-install mysqli mbstring pdo pdo_mysql xml pcntl zip

RUN curl -s https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin/ --filename=composer

ARG APP_DEBUG=false
ENV APP_DEBUG ${APP_DEBUG}
RUN if [ ${APP_DEBUG} = true ]; then \
    pecl install xdebug \
    && \
    docker-php-ext-enable xdebug \
    ;fi

COPY .docker/php/xdebug.ini /usr/local/etc/php/conf.d/xdebug.ini

RUN pecl install -o -f redis \
    &&  rm -rf /tmp/pear \
    &&  docker-php-ext-enable redis

RUN rm /var/cache/apk/*


### ----------------------------------------------------------
### PHP, Nginx, Supervisor configuration
### ----------------------------------------------------------

COPY .docker/php/supervisor/supervisord.conf /etc/supervisord.conf
COPY .docker/php/supervisor/supervisord-api.conf /etc/supervisord-api.conf
COPY .docker/php/supervisor/supervisord-cronjob.conf /etc/supervisord-cronjob.conf
COPY .docker/php/supervisor/supervisord-worker.conf /etc/supervisord-worker.conf

COPY .docker/nginx/nginx.conf /etc/nginx/nginx.conf
COPY .docker/nginx/default.conf /etc/nginx/conf.d/default.conf

COPY .docker/php/php.ini /usr/local/etc/php/conf.d/php.ini

WORKDIR /var/www

### ----------------------------------------------------------
### Laravel
### ----------------------------------------------------------

COPY public /usr/share/nginx/html
COPY . /var/www

RUN set -x && \
    touch /var/log/cron.log && \
    chown -R www-data:www-data /usr/share/nginx/html && \
    chown -R www-data:www-data /var/www && \
    find /var/www/storage -type f -exec chmod 664 {} \; && \
    find /var/www/storage -type d -exec chmod 770 {} \;

ARG APP_ENV=production
ENV APP_ENV ${APP_ENV}

RUN set -x && \
    if [ "${APP_ENV}" == "local" ] || [ "${APP_ENV}" == "development" ] || [ "${APP_ENV}" == "dev" ]; then \
        composer install ; \
    else \
        composer install --no-dev ; \
    fi

CMD ["nginx", "-g", "daemon off;"]
