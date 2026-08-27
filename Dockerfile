# Pinned to a minor version rather than :latest so a rebuild is reproducible and
# a base image bump is a reviewable change. Renovate updates this line.
FROM alpine:3.24

# rclone comes from the Alpine community repository so apk verifies its
# signature. Alpine's build can lag upstream; if a newer release is needed, pin
# the version and verify its published SHA256.
RUN apk add --no-cache \
      docker-cli \
      curl \
      mutt \
      openssl \
      rclone \
      sqlite \
      tar \
      tzdata

# Send the log to PID 1's stdout so "docker logs backup" shows it.
RUN ln -sf /proc/1/fd/1 /var/log/backup.log

COPY scripts/backup_init.sh /
COPY scripts/backup.sh /

RUN chmod +x /backup_init.sh /backup.sh && \
    ln -sf /backup.sh /usr/local/bin/backup.sh && \
    ln -sf /backup.sh /usr/local/bin/backup

# Reports unhealthy when crond is not running, which is the failure that stops
# scheduled backups without stopping the container.
HEALTHCHECK --interval=5m --timeout=10s --start-period=30s --retries=2 \
  CMD pgrep crond >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/backup_init.sh"]
