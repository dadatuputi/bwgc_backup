# Failure and status mails call email_send without an attachment. They must
# reach mutt: here it cannot connect (port 1), so the script logs an e-mail
# error instead of stopping on the missing argument.
reset_data
mail_env="BACKUP_EMAIL_NOTIFY=true SMTP_HOST=127.0.0.1 SMTP_PORT=1 SMTP_SECURITY=starttls SMTP_USERNAME=user SMTP_PASSWORD=secret SMTP_FROM=vault@example.com SMTP_FROM_NAME=Test BACKUP_EMAIL_TO=admin@example.com"

rm -f /tmp/muttrc
# shellcheck disable=SC2086
OUT=$(env $mail_env sh /backup.sh bogus 2>&1)
assert_not_contains "$OUT" "parameter not set" "failure mail: no stop on the missing attachment"
assert_contains "$OUT" "Email error"           "failure mail: handed to mutt"

rm -f /tmp/muttrc /data/backups/bw_backup_*
# shellcheck disable=SC2086
OUT=$(env $mail_env METADATA_HOST=169.254.255.255 sh /backup.sh check 2>&1)
assert_not_contains "$OUT" "parameter not set" "status mail: no stop on the missing attachment"
assert_contains "$OUT" "Email error"           "status mail: handed to mutt"
