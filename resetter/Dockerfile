FROM alpine:3.20

# supercronic - cron for containers (logs to stdout, no syslog needed)
ARG SUPERCRONIC_VERSION=v0.2.33
RUN set -eux; \
    ARCH="$(uname -m)"; \
    case "$ARCH" in \
      x86_64)  SUPERCRONIC_ARCH=linux-amd64 ;; \
      aarch64) SUPERCRONIC_ARCH=linux-arm64 ;; \
      armv7l)  SUPERCRONIC_ARCH=linux-arm ;; \
      *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac; \
    wget -q "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-${SUPERCRONIC_ARCH}" \
      -O /usr/local/bin/supercronic \
 && chmod +x /usr/local/bin/supercronic

RUN apk add --no-cache bash docker-cli coreutils

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
