# docker-keeper: autoheal + autostart + cron по меткам контейнеров. См. README.md.
ARG DOCKER_VERSION=29
FROM docker:${DOCKER_VERSION}-cli

# tzdata: crond считает расписание в TZ контейнера
RUN apk add --no-cache tzdata

COPY keeper.sh keeper-job /usr/local/bin/
RUN chmod +x /usr/local/bin/keeper.sh /usr/local/bin/keeper-job

ENTRYPOINT ["/usr/local/bin/keeper.sh"]
