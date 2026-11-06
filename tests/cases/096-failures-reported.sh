unset BACKUP_ENCRYPTION_KEY 2>/dev/null || true
no_smtp="SMTP_HOST=127.0.0.1 SMTP_PORT=1 SMTP_SECURITY=off SMTP_FROM=vault@example.com BACKUP_EMAIL_TO=admin@example.com METADATA_HOST=169.254.255.255"

reset_data
rm -f /tmp/muttrc
# shellcheck disable=SC2086
OUT=$(env $no_smtp sh /backup.sh email 2>&1); STATUS=$?
assert_status "$STATUS" 1 "email method fails when the mail cannot be sent"
assert_contains "$OUT" "Could not e-mail the archive" "the failed send is named"
assert_not_contains "$OUT" "Backup to email completed" "it is not reported as completed"

reset_data
printf 'not an rclone config\n' > /tmp/broken-rclone.conf
OUT=$(BACKUP_RCLONE_CONF=/tmp/broken-rclone.conf sh /backup.sh rclone 2>&1); STATUS=$?
assert_status "$STATUS" 1 "rclone fails on a configuration it cannot read"
assert_contains "$OUT" "Could not read the rclone configuration" "the unreadable configuration is named"
printf '# no remotes yet\n' > /tmp/empty-rclone.conf
OUT=$(BACKUP_RCLONE_CONF=/tmp/empty-rclone.conf sh /backup.sh rclone 2>&1); STATUS=$?
assert_status "$STATUS" 1 "rclone fails when no remote is configured"
assert_contains "$OUT" "No remotes are configured" "the missing remote is named"
rm -f /tmp/broken-rclone.conf /tmp/empty-rclone.conf

mkdir -p /tmp/shim
printf '#!/bin/sh\nprintf partial\nexit 2\n' > /tmp/shim/tar
chmod +x /tmp/shim/tar
reset_data
OUT=$(PATH="/tmp/shim:$PATH" BACKUP_ENCRYPTION_KEY="k" sh /backup.sh local 2>&1); STATUS=$?
assert_status "$STATUS" 1 "an encrypted backup fails when tar fails"
assert_eq "$(ls /data/backups | grep -c 'bw_backup_')" 0 "no encrypted archive is left behind"
assert_eq "$(ls -A /data/backups | grep -c 'partial')" 0 "no partial file is left behind"
reset_data
OUT=$(PATH="/tmp/shim:$PATH" sh /backup.sh local 2>&1); STATUS=$?
assert_status "$STATUS" 1 "a plain backup fails when tar fails"
assert_eq "$(ls -A /data/backups | grep -c 'bw_backup_')" 0 "no truncated archive is left behind"
rm -rf /tmp/shim

reset_data
sh /backup.sh local >/dev/null 2>&1
assert_eq "$(ls -A /data/backups | grep -c '^bw_backup_')" 1 "a good backup is renamed into place"
assert_eq "$(ls -A /data/backups | grep -c 'partial')" 0 "and leaves no partial file"

reset_data
rm -f /data/backups/bw_backup_* /tmp/muttrc
# shellcheck disable=SC2086
env $no_smtp BACKUP_EMAIL_NOTIFY=true sh /backup.sh check >/dev/null 2>&1
assert_no_file /data/backups/.last-status-alert "an unsent alert is not remembered as sent"

for pw in 'plain' 'has"quote' 'has`id`tick' 'has$HOME' 'back\slash' "it's"; do
	rm -f /tmp/muttrc
	env SMTP_HOST=mail.example.com SMTP_PORT=587 SMTP_SECURITY=starttls SMTP_USERNAME=user SMTP_PASSWORD="$pw" \
		BACKUP_EMAIL_NOTIFY=true METADATA_HOST=169.254.255.255 sh /backup.sh check >/dev/null 2>&1
	GOT=$(mutt -F /tmp/muttrc -Q smtp_pass 2>/dev/null | sed -n 's/^smtp_pass="\(.*\)"$/\1/p' | sed 's/\\\(.\)/\1/g')
	assert_eq "$GOT" "$pw" "mutt reads the password $pw unchanged"
done
rm -f /tmp/muttrc
