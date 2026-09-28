# The success notice is a notice, not a delivery. It must not attach the
# archive: the email method already sends it, with restore instructions, and
# the other methods put it where they were asked to. A mutt stand-in records
# each call's arguments and body, so what would have been sent is checked
# without an SMTP server.
mail_env="BACKUP_EMAIL_NOTIFY=true SMTP_HOST=127.0.0.1 SMTP_PORT=1 SMTP_SECURITY=starttls SMTP_USERNAME=user SMTP_PASSWORD=secret SMTP_FROM=vault@example.com SMTP_FROM_NAME=Test BACKUP_EMAIL_TO=admin@example.com"

mkdir -p /tmp/mutt-shim
cat > /tmp/mutt-shim/mutt <<'EOF'
#!/bin/sh
n=$(ls /tmp/mutt-calls/args.* 2>/dev/null | wc -l)
echo "$*" > "/tmp/mutt-calls/args.$n"
cat > "/tmp/mutt-calls/body.$n"
EOF
chmod +x /tmp/mutt-shim/mutt
reset_calls() { rm -rf /tmp/mutt-calls; mkdir -p /tmp/mutt-calls; }
calls()        { ls /tmp/mutt-calls | grep -c '^args\.'; }
attachments()  { cat /tmp/mutt-calls/args.* | grep -c -- ' -a '; }

# local: one notice, nothing attached, the archive named in the body.
reset_data
reset_calls
rm -f /tmp/muttrc
# shellcheck disable=SC2086
env $mail_env PATH="/tmp/mutt-shim:$PATH" sh /backup.sh local >/dev/null 2>&1
assert_status $? 0 "local backup with a success notice succeeds"
assert_eq "$(calls)" 1 "local: one mail, the notice"
assert_eq "$(attachments)" 0 "local: the notice carries no attachment"
assert_contains "$(cat /tmp/mutt-calls/args.0)" "Backup Successful" "local: the mail is the success notice"
assert_contains "$(cat /tmp/mutt-calls/body.0)" "/data/backups/bw_backup_" "local: the notice names the archive"

# email: the backup itself is attached once, and the notice that follows is
# not a second copy.
reset_data
reset_calls
rm -f /tmp/muttrc
# shellcheck disable=SC2086
env $mail_env PATH="/tmp/mutt-shim:$PATH" sh /backup.sh email >/dev/null 2>&1
assert_status $? 0 "email backup with a success notice succeeds"
assert_eq "$(calls)" 2 "email: the backup, then the notice"
assert_eq "$(attachments)" 1 "email: the archive is sent once"
assert_not_contains "$(cat /tmp/mutt-calls/args.1)" " -a " "email: the notice carries no attachment"

# An unset SMTP_FROM_NAME must not stop the script where a mail is sent.
reset_data
reset_calls
rm -f /tmp/muttrc
# shellcheck disable=SC2086
OUT=$(env $mail_env PATH="/tmp/mutt-shim:$PATH" env -u SMTP_FROM_NAME sh /backup.sh local 2>&1)
assert_status $? 0 "an unset SMTP_FROM_NAME does not stop a backup"
assert_not_contains "$OUT" "parameter not set" "an unset SMTP_FROM_NAME is defaulted"
assert_contains "$(cat /tmp/mutt-calls/args.0)" "Bitwarden - Backup Successful" "the default from-name is used in the subject"

rm -rf /tmp/mutt-shim /tmp/mutt-calls /tmp/muttrc
