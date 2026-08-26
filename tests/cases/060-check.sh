# The status check reports on backup freshness. The OS milestone half needs the
# GCE metadata server, which is absent here, and must degrade rather than fail.
reset_data
unset BACKUP_ENCRYPTION_KEY 2>/dev/null || true
sh /backup.sh local >/dev/null 2>&1

OUT=$(BACKUP_EMAIL_NOTIFY=false METADATA_HOST=169.254.255.255 sh /backup.sh check 2>&1); STATUS=$?
assert_status "$STATUS" 0 "check passes when a fresh backup exists"
assert_contains "$OUT" "Newest backup is within" "reports backup freshness"
assert_contains "$OUT" "skipping the OS check"   "degrades cleanly with no metadata server"

# Now age the backup past the threshold.
for f in /data/backups/bw_backup_*; do touch -t 200001010000 "$f"; done
OUT=$(BACKUP_EMAIL_NOTIFY=false BACKUP_MAX_AGE_DAYS=8 METADATA_HOST=169.254.255.255 sh /backup.sh check 2>&1); STATUS=$?
assert_status "$STATUS" 1 "check fails when backups are stale"
assert_contains "$OUT" "older than 8 days" "names the threshold it breached"

# And with no backups at all.
rm -f /data/backups/bw_backup_*
OUT=$(BACKUP_EMAIL_NOTIFY=false METADATA_HOST=169.254.255.255 sh /backup.sh check 2>&1); STATUS=$?
assert_status "$STATUS" 1 "check fails when there are no backups"
assert_contains "$OUT" "no backups at all" "says there are none"
