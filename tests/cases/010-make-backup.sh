# An unencrypted backup should contain the database and the data directories.
reset_data
unset BACKUP_ENCRYPTION_KEY 2>/dev/null || true
OUT=$(sh /backup.sh local 2>&1); STATUS=$?
assert_status "$STATUS" 0 "backup exits 0"
ARCHIVE=$(ls -t /data/backups/bw_backup_* 2>/dev/null | head -1)
assert_file "$ARCHIVE" "archive written"
LIST=$(tar tzf "$ARCHIVE" 2>/dev/null)
assert_contains "$LIST" "db.sqlite3"        "archive contains the database"
assert_contains "$LIST" "data/attachments"  "archive contains attachments"
assert_contains "$LIST" "data/rsa_key.der"  "archive contains the RSA key"
assert_not_contains "$LIST" "data/backups"  "archive does not contain the backups directory"
assert_no_file /tmp/db.sqlite3              "the plaintext staging copy is cleaned up"

# Two backups in the same second must not collide. A collision here destroys
# the archive a concurrent restore is reading from.
reset_data
unset BACKUP_ENCRYPTION_KEY 2>/dev/null || true
sh /backup.sh local >/dev/null 2>&1
sh /backup.sh local >/dev/null 2>&1
sh /backup.sh local >/dev/null 2>&1
assert_eq "$(ls /data/backups/bw_backup_* 2>/dev/null | wc -l | tr -d ' ')" "3" \
  "three rapid backups produce three distinct files"
