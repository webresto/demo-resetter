FROM alpine:3.20

# supercronic - cron for containers (logs to stdout, no syslog needed)
ARG SUPERCRONIC_VERSION=v0.2.33
ARG SUPERCRONIC_ARCH=linux-amd64
RUN wget -q "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-${SUPERCRONIC_ARCH}" \
      -O /usr/local/bin/supercronic \
 && chmod +x /usr/local/bin/supercronic

RUN apk add --no-cache bash docker-cli coreutils

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
