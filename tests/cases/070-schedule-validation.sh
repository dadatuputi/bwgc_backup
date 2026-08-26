# A malformed schedule must be refused at startup rather than producing a
# crontab line cron silently ignores.
for bad in "" "bogus" "0 0 * *" "0 0 * * 6 extra"; do
	OUT=$(BACKUP=local BACKUP_SCHEDULE="$bad" sh /backup_init.sh 2>&1); STATUS=$?
	assert_status "$STATUS" 1 "rejects schedule: '${bad:-<empty>}'"
	assert_contains "$OUT" "ERROR: BACKUP_SCHEDULE" "explains the rejection: '${bad:-<empty>}'"
done

# Newline injection: a second crontab line must not be smuggled in.
OUT=$(BACKUP=local BACKUP_SCHEDULE="$(printf '0 0 * * 6\n* * * * * touch /tmp/pwned')" sh /backup_init.sh 2>&1); STATUS=$?
assert_status "$STATUS" 1 "rejects a schedule containing a newline"
assert_no_file /tmp/pwned "no injected crontab entry ran"
