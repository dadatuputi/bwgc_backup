# Pruning must remove old backups and nothing else.
reset_data
KEEP=/data/backups/notes.txt
printf 'operator notes\n' > "$KEEP"
OLD=/data/backups/bw_backup_2000-01-01-000000.tar.gz
printf 'old\n' > "$OLD"
touch -d "2000-01-01" "$OLD" "$KEEP" 2>/dev/null || touch -t 200001010000 "$OLD" "$KEEP"

unset BACKUP_ENCRYPTION_KEY 2>/dev/null || true
BACKUP_DAYS=1 sh /backup.sh local >/dev/null 2>&1
assert_no_file "$OLD"  "an old bw_backup_* is pruned"
assert_file "$KEEP"    "an unrelated old file is left alone"
