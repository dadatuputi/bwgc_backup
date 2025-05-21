FROM alpine:latest

RUN apk --update --no-cache add sqlite mutt tzdata curl openssl tar docker-cli
RUN ln -sf /proc/1/fd/1 /var/log/backup.log

# Install rclone
RUN curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip && \
    unzip rclone-current-linux-amd64.zip && \
    cp rclone-*-linux-amd64/rclone /usr/bin/rclone && \
    chown root:root /usr/bin/rclone && \
    chmod 755 /usr/bin/rclone && \
    rm -f rclone-current-linux-amd64.zip && \
    rm -rf rclone-*-linux-amd64/

COPY scripts/backup_init.sh /
COPY scripts/backup.sh /

# Make scripts executable
RUN chmod +x /backup_init.sh /backup.sh

# Create symlinks to PATH location /usr/local/bin
RUN ln -sf /backup.sh /usr/local/bin/backup.sh && \
    ln -sf /backup.sh /usr/local/bin/backup

ENTRYPOINT ["/backup_init.sh"]
