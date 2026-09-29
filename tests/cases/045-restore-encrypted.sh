# A restore from an encrypted archive: 020 proves the archive decrypts with
# openssl, this proves restore itself does, with the key from the environment,
# and refuses cleanly with the wrong key or none.
reset_data
export BACKUP_ENCRYPTION_KEY='fixture-only p a s s"w0rd$with spaces'
sh /backup.sh local >/dev/null 2>&1
ARCHIVE=$(ls -t /data/backups/bw_backup_*.aes256 2>/dev/null | head -1)
assert_file "$ARCHIVE" "encrypted archive written"

sqlite3 /data/db.sqlite3 "insert into t values(999);"
BEFORE=$(db_hash)

# The wrong key must change nothing. An emergency backup of the live data is
# taken before the restore is attempted, so the count of archives may grow;
# the database itself must not.
OUT=$(BACKUP_ENCRYPTION_KEY=not-the-key RESTORE_FORCE=true sh /backup.sh restore "$ARCHIVE" 2>&1); STATUS=$?
assert_status "$STATUS" 1                   "restore with the wrong key exits non-zero"
assert_contains "$OUT" "Failed to decrypt"  "restore with the wrong key says so"
assert_eq "$(db_hash)" "$BEFORE"            "restore with the wrong key leaves the database alone"

# No key and no terminal: refuse rather than hang on a prompt.
OUT=$(BACKUP_ENCRYPTION_KEY='' RESTORE_FORCE=true sh /backup.sh restore "$ARCHIVE" 2>&1 </dev/null); STATUS=$?
assert_status "$STATUS" 1                   "restore with no key and no terminal exits non-zero"
assert_contains "$OUT" "BACKUP_ENCRYPTION_KEY" "restore with no key names the variable to set"
assert_eq "$(db_hash)" "$BEFORE"            "restore with no key leaves the database alone"

# The right key, from the environment, restores the archived content.
OUT=$(RESTORE_FORCE=true sh /backup.sh restore "$ARCHIVE" 2>&1); STATUS=$?
assert_status "$STATUS" 0                   "restore with the right key exits 0"
assert_contains "$OUT" "Detected encrypted backup file" "restore recognises the encrypted archive"
assert_ne "$(db_hash)" "$BEFORE"            "restore with the right key replaced the database"
assert_eq "$(sqlite3 /data/db.sqlite3 "select count(*) from t;" 2>/dev/null)" "1" "restored content is the archived database"
unset BACKUP_ENCRYPTION_KEY
