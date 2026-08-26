# With no Docker daemon reachable, restore must refuse -- and refuse without
# having changed anything at all. This container deliberately has no socket.
reset_data
unset BACKUP_ENCRYPTION_KEY 2>/dev/null || true
sh /backup.sh local >/dev/null 2>&1
ARCHIVE=$(ls -t /data/backups/bw_backup_* | head -1)

sqlite3 /data/db.sqlite3 "insert into t values(999);"
printf 'STALE' > /data/db.sqlite3-wal
printf 'STALE' > /data/db.sqlite3-shm
BEFORE=$(db_hash)
COUNT_BEFORE=$(ls /data/backups | wc -l)

OUT=$(sh /backup.sh restore "$ARCHIVE" 2>&1); STATUS=$?
assert_status "$STATUS" 1                        "restore exits non-zero"
assert_contains "$OUT" "cannot reach the Docker daemon" "explains why it refused"
assert_contains "$OUT" "Nothing has been changed"       "states nothing changed"
assert_eq "$(db_hash)" "$BEFORE"                 "database is untouched"
assert_eq "$(ls /data/backups | wc -l)" "$COUNT_BEFORE" "no emergency backup written (a true no-op)"
assert_file /data/db.sqlite3-wal                 "sidecars untouched on abort"
