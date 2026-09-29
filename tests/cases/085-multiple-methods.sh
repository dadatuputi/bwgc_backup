# One invocation can name several methods, comma-separated (the cron line
# does), and one archive serves all of them. A method that fails must not
# stop the others, and the run's exit status must say whether any failed.
RC=/tmp/rclone-multi.conf
REMOTE_DIR=/tmp/remote-multi
printf '[bk]\ntype = local\n' > "$RC"
unset BACKUP_ENCRYPTION_KEY 2>/dev/null || true
# Archives in a directory, by glob rather than ls.
archives() { set -- "$1"/bw_backup_*; [ -e "$1" ] && echo $# || echo 0; }

# local,rclone: one archive, present locally and on the remote.
reset_data
rm -rf "$REMOTE_DIR"; mkdir -p "$REMOTE_DIR"
OUT=$(BACKUP_RCLONE_CONF="$RC" BACKUP_RCLONE_DEST="$REMOTE_DIR" sh /backup.sh local,rclone 2>&1); STATUS=$?
assert_status "$STATUS" 0 "local,rclone succeeds"
assert_eq "$(archives /data/backups)" 1 "one archive is made for both methods"
assert_eq "$(archives "$REMOTE_DIR")" 1 "the archive reaches the remote"
assert_contains "$OUT" "Performing 'local' backup"  "the local method runs"
assert_contains "$OUT" "Performing 'rclone' backup" "the rclone method runs"

# A failing method does not stop the next one. The run exits 0 as long as
# one method succeeded: the failure is logged, and mailed when notifications
# are on, but only "All backup methods failed" is an exit status of 1.
reset_data
rm -rf "$REMOTE_DIR"; mkdir -p "$REMOTE_DIR"
printf 'not a directory\n' > /tmp/remote-multi-file
OUT=$(BACKUP_RCLONE_CONF="$RC" BACKUP_RCLONE_DEST=/tmp/remote-multi-file/sub sh /backup.sh rclone,local 2>&1); STATUS=$?
assert_status "$STATUS" 0 "a run with one failed and one successful method exits 0"
assert_contains "$OUT" "Backup via rclone failed" "the failed method is reported"
assert_contains "$OUT" "Performing 'local' backup" "the method after a failed one still runs"
assert_contains "$OUT" "Backup to local completed" "the method after a failed one succeeds"
assert_eq "$(archives /data/backups)" 1 "the local copy is still made"
rm -f /tmp/remote-multi-file

# When every method fails, the run says so and exits 1.
reset_data
printf 'not a directory\n' > /tmp/remote-multi-file
OUT=$(BACKUP_RCLONE_CONF="$RC" BACKUP_RCLONE_DEST=/tmp/remote-multi-file/sub sh /backup.sh rclone 2>&1); STATUS=$?
assert_status "$STATUS" 1 "a run whose every method failed exits 1"
assert_contains "$OUT" "All backup methods failed" "a run whose every method failed says so"
rm -f /tmp/remote-multi-file

# An invalid name anywhere in the list stops the run before any archive is made.
reset_data
OUT=$(sh /backup.sh local,bogus 2>&1); STATUS=$?
assert_status "$STATUS" 1 "an invalid method in the list fails the run"
assert_contains "$OUT" "Invalid backup method 'bogus'" "the invalid method is named"
assert_eq "$(archives /data/backups)" 0 "nothing is backed up when the list is invalid"

# Two remotes, one of them unreachable: the good one still gets the archive,
# and the run reports which failed.
reset_data
rm -rf "$REMOTE_DIR"; mkdir -p "$REMOTE_DIR"
printf '[bk]\ntype = local\n\n[nowhere]\ntype = sftp\nhost = 127.0.0.1\nport = 1\nuser = nobody\nkey_file = /nonexistent-key\n' > "$RC"
OUT=$(BACKUP_RCLONE_CONF="$RC" BACKUP_RCLONE_DEST="$REMOTE_DIR" sh /backup.sh rclone 2>&1); STATUS=$?
assert_status "$STATUS" 1 "an unreachable remote fails the run"
assert_contains "$OUT" "Failed to copy to 1 of 2 remotes" "the run counts the remote that failed"
assert_contains "$OUT" "Copy log with nowhere:" "the failed remote is named"
assert_eq "$(archives "$REMOTE_DIR")" 1 "the reachable remote still receives the archive"

rm -rf "$REMOTE_DIR" "$RC"
