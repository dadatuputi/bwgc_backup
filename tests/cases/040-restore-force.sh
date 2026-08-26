# RESTORE_FORCE is the operator asserting the vault is already stopped.
reset_data
unset BACKUP_ENCRYPTION_KEY 2>/dev/null || true
sh /backup.sh local >/dev/null 2>&1
ARCHIVE=$(ls -t /data/backups/bw_backup_* | head -1)

sqlite3 /data/db.sqlite3 "insert into t values(999);"
printf 'STALE' > /data/db.sqlite3-wal
printf 'STALE' > /data/db.sqlite3-shm
BEFORE=$(db_hash)

OUT=$(RESTORE_FORCE=true sh /backup.sh restore "$ARCHIVE" 2>&1); STATUS=$?
assert_status "$STATUS" 0             "forced restore exits 0"
assert_ne "$(db_hash)" "$BEFORE"      "database was actually replaced"
assert_no_file /data/db.sqlite3-wal   "stale -wal removed"
assert_no_file /data/db.sqlite3-shm   "stale -shm removed"

# The restored database must be the ORIGINAL content, not the modified one.
ROWS=$(sqlite3 /data/db.sqlite3 "select count(*) from t;" 2>/dev/null)
assert_eq "$ROWS" "1"                 "restored content is from the archive, not the live database"
