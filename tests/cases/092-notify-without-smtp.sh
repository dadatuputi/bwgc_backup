# A .env from before SMTP was required has BACKUP_EMAIL_NOTIFY=true and no SMTP
# settings at all. The backup must still be made, and the missing settings
# reported, rather than the script stopping on an unset SMTP_HOST.
reset_data
unset BACKUP_ENCRYPTION_KEY SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_SECURITY SMTP_FROM 2>/dev/null || true
rm -f /tmp/muttrc /data/backups/bw_backup_*
OUT=$(env BACKUP_EMAIL_NOTIFY=true sh /backup.sh local 2>&1); STATUS=$?
assert_status "$STATUS" 0                       "notify without SMTP: backup exits 0"
assert_not_contains "$OUT" "parameter not set"  "notify without SMTP: no stop on SMTP_HOST"
assert_contains "$OUT" "SMTP_HOST is not set"   "notify without SMTP: says why no mail is sent"
ARCHIVE=$(ls -t /data/backups/bw_backup_* 2>/dev/null | head -1)
assert_file "$ARCHIVE"                          "notify without SMTP: archive written"
assert_no_file /tmp/muttrc                      "notify without SMTP: no half-configured mutt"
