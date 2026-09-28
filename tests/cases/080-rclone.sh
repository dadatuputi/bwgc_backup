# Pushing to an rclone remote must only add archives, never mirror a local
# deletion, and prune nothing but bw_backup_* archives. The remote is a real
# rclone "local" backend, so this exercises rclone itself.
RC=/tmp/rclone-test.conf
REMOTE_DIR=/tmp/remote
printf '[bk]\ntype = local\n' > "$RC"

reset_remote() {
	rm -rf "$REMOTE_DIR"
	mkdir -p "$REMOTE_DIR"
	for d in 01 02 03; do
		printf 'old\n' > "$REMOTE_DIR/bw_backup_2000-01-$d-000000.tar.gz"
	done
	printf 'operator notes\n' > "$REMOTE_DIR/notes.txt"
}
make_old() {
	touch -d "2000-01-01" "$@" 2>/dev/null || touch -t 200001010000 "$@"
}
remote_archives() { ls "$REMOTE_DIR" | grep -c '^bw_backup_'; }

unset BACKUP_ENCRYPTION_KEY 2>/dev/null || true

# A local directory that lost its archives must not empty the remote.
reset_data
reset_remote
printf 'state\n' > /data/backups/.last-status-alert
BACKUP_RCLONE_CONF="$RC" BACKUP_RCLONE_DEST="$REMOTE_DIR" sh /backup.sh rclone >/dev/null 2>&1
assert_status $? 0 "rclone backup succeeds"
assert_eq "$(remote_archives)" 4 "archives missing locally stay on the remote"
assert_file "$REMOTE_DIR/notes.txt" "an unrelated file on the remote is left alone"
assert_no_file "$REMOTE_DIR/.last-status-alert" "only archives are copied"

# The remote follows the BACKUP_DAYS age rule of the local directory.
reset_data
reset_remote
RECENT="$REMOTE_DIR/bw_backup_2001-01-01-000000.tar.gz"
printf 'recent\n' > "$RECENT"
make_old "$REMOTE_DIR"/bw_backup_2000-* "$REMOTE_DIR/notes.txt"
BACKUP_DAYS=1 BACKUP_RCLONE_CONF="$RC" BACKUP_RCLONE_DEST="$REMOTE_DIR" sh /backup.sh rclone >/dev/null 2>&1
assert_status $? 0 "rclone backup with BACKUP_DAYS succeeds"
assert_no_file "$REMOTE_DIR/bw_backup_2000-01-01-000000.tar.gz" "an old archive on the remote is deleted"
assert_file "$RECENT" "a recent archive on the remote is kept"
assert_file "$REMOTE_DIR/notes.txt" "pruning by age leaves unrelated files alone"

# The remote ends up with the archives the local directory keeps: an archive
# pruned locally is not sent, so none is uploaded only to be deleted.
reset_data
rm -rf "$REMOTE_DIR"
mkdir -p "$REMOTE_DIR"
printf 'old\n' > /data/backups/bw_backup_2000-01-01-000000.tar.gz
make_old /data/backups/bw_backup_2000-01-01-000000.tar.gz
printf 'recent\n' > /data/backups/bw_backup_2001-01-01-000000.tar.gz
BACKUP_DAYS=1 BACKUP_RCLONE_CONF="$RC" BACKUP_RCLONE_DEST="$REMOTE_DIR" sh /backup.sh rclone >/dev/null 2>&1
assert_status $? 0 "rclone backup into an empty remote succeeds"
assert_eq "$(ls "$REMOTE_DIR")" "$(ls /data/backups | grep '^bw_backup_')" "the remote holds the local archives"
assert_no_file "$REMOTE_DIR/bw_backup_2000-01-01-000000.tar.gz" "an archive pruned locally is not uploaded"

# Archives are sent one at a time: each rclone transfer holds its own upload
# buffer, and a container memory limit must not kill the copy.
reset_data
reset_remote
mkdir -p /tmp/shim
cat > /tmp/shim/rclone <<'EOF'
#!/bin/sh
echo "$*" >> /tmp/rclone-args
exec /usr/bin/rclone "$@"
EOF
chmod +x /tmp/shim/rclone
rm -f /tmp/rclone-args
PATH="/tmp/shim:$PATH" BACKUP_RCLONE_CONF="$RC" BACKUP_RCLONE_DEST="$REMOTE_DIR" sh /backup.sh rclone >/dev/null 2>&1
assert_status $? 0 "rclone backup through the shim succeeds"
assert_contains "$(grep ' copy ' /tmp/rclone-args)" "--transfers 1" "the copy sends one archive at a time"
rm -rf /tmp/shim /tmp/rclone-args

# A failed copy is reported as a failed backup.
reset_data
printf 'not a directory\n' > /tmp/remote-file
BACKUP_RCLONE_CONF="$RC" BACKUP_RCLONE_DEST=/tmp/remote-file/sub sh /backup.sh rclone >/dev/null 2>&1
assert_status $? 1 "a failed copy fails the backup"
rm -f /tmp/remote-file
