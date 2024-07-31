#!/bin/bash
# vim:sw=4:ts=4:et

set -e

entrypoint_log() {
    if [ -z "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ]; then
        echo "$@"
    fi
}

if [ "$1" = "nginx" -o "$1" = "nginx-debug" ]; then
    if /usr/bin/find "/docker-entrypoint.d/" -mindepth 1 -maxdepth 1 -type f -print -quit 2>/dev/null | read v; then
        entrypoint_log "$0: /docker-entrypoint.d/ is not empty, will attempt to perform configuration"

        entrypoint_log "$0: Looking for shell scripts in /docker-entrypoint.d/"
        find "/docker-entrypoint.d/" -follow -type f -print | sort -V | while read -r f; do
            case "$f" in
                *.envsh)
                    if [ -x "$f" ]; then
                        entrypoint_log "$0: Sourcing $f";
                        . "$f"
                    else
                        # warn on shell scripts without exec bit
                        entrypoint_log "$0: Ignoring $f, not executable";
                    fi
                    ;;
                *.sh)
                    if [ -x "$f" ]; then
                        entrypoint_log "$0: Launching $f";
                        "$f"
                    else
                        # warn on shell scripts without exec bit
                        entrypoint_log "$0: Ignoring $f, not executable";
                    fi
                    ;;
                *) entrypoint_log "$0: Ignoring $f";;
            esac
        done

        entrypoint_log "$0: Configuration complete; ready for start up"
    else
        entrypoint_log "$0: No files found in /docker-entrypoint.d/, skipping configuration"
    fi

    # init app
    env=${APP_ENV:-production}

    if [ "$env" = "local" ] || [ "$env" = "dev" ] || [ "$env" = "development" ]; then
        composer install
    else
        php artisan optimize:clear
        composer dump-autoload
    fi

     # Setup Cloudfront keypem
    if [ -n "$CLOUDFRONT_PRIVATE_KEY" ]; then
        entrypoint_log "$0: CLOUDFRONT_PRIVATE_KEY is found"
        echo -e $CLOUDFRONT_PRIVATE_KEY > /var/www/storage/$CLOUDFRONT_PRIVATE_KEY_PATH
    else
        entrypoint_log "$0: CLOUDFRONT_PRIVATE_KEY is not found"
    fi

    # Run Container by Role
    role=${CONTAINER_ROLE:-all}
    entrypoint_log "$0: CONTAINER_ROLE: $CONTAINER_ROLE"
    if [ "$role" = "api" ]; then
        entrypoint_log "$0: supervisord -n -c /etc/supervisord-api.conf"
        supervisord -n -c /etc/supervisord-api.conf
    elif [ "$role" = "cronjob" ]; then
        entrypoint_log "$0: php artisan migrate"
        php artisan migrate
        entrypoint_log "$0: supervisord -n -c /etc/supervisord-cronjob.conf"
        supervisord -n -c /etc/supervisord-cronjob.conf
    elif [ "$role" = "worker" ]; then
        entrypoint_log "$0: supervisord -n -c /etc/supervisord-worker.conf"
       supervisord -n -c /etc/supervisord-worker.conf
    else
        entrypoint_log "$0: supervisord -n -c /etc/supervisord.conf"
        supervisord -n -c /etc/supervisord.conf
    fi
else
    exec "$@"
fi



