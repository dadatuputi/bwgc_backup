# End to end: mutt, with the muttrc the script writes, delivering to a real
# SMTP server. 090 checks the muttrc's text and 092 what mutt is handed; this
# checks what arrives. The server is mailpit, reached through BWGC_SMTP_HOST
# and BWGC_SMTP_PORT, with its API at BWGC_MAILPIT_API; run-tests.sh passes
# them in and the build workflow provides the server. Without them the case
# is skipped.
if [ -n "${BWGC_SMTP_HOST:-}" ] && [ -n "${BWGC_MAILPIT_API:-}" ]; then
	: "${BWGC_SMTP_PORT:=1025}"
	mp_clear()  { curl -sS -X DELETE "$BWGC_MAILPIT_API/api/v1/messages" >/dev/null; }
	mp_total()  { curl -sS "$BWGC_MAILPIT_API/api/v1/messages" | sed -n 's/^{"total":\([0-9]*\).*/\1/p'; }
	# The messages matching a mailpit search, as its JSON list.
	mp_search() { curl -sS -G --data-urlencode "query=$1" "$BWGC_MAILPIT_API/api/v1/search"; }
	mail_env="SMTP_HOST=$BWGC_SMTP_HOST SMTP_PORT=$BWGC_SMTP_PORT SMTP_FROM=vault@example.com SMTP_FROM_NAME=Test BACKUP_EMAIL_TO=admin@example.com BACKUP_EMAIL_NOTIFY=true METADATA_HOST=169.254.255.255"
	unset BACKUP_ENCRYPTION_KEY 2>/dev/null || true
	# The script writes the muttrc once and keeps it, so each run starts clean.
	fresh() { reset_data; rm -f /tmp/muttrc; mp_clear; }

	# SMTP_SECURITY=off to a relay that takes mail without a login: the email
	# method sends the archive, then the notice, and only the first carries it.
	fresh
	# shellcheck disable=SC2086
	env $mail_env SMTP_SECURITY=off SMTP_USERNAME= SMTP_PASSWORD= sh /backup.sh email >/dev/null 2>&1
	assert_status $? 0 "email backup over plain SMTP without a login succeeds"
	assert_eq "$(mp_total)" 2 "the archive mail and the notice both arrive"
	backup_msg=$(mp_search 'subject:"bw_backup"')
	assert_contains "$backup_msg" '"Attachments":1' "the archive mail carries one attachment"
	assert_contains "$backup_msg" '"Address":"vault@example.com"' "the mail is from SMTP_FROM"
	assert_contains "$backup_msg" '"Address":"admin@example.com"' "the mail is to BACKUP_EMAIL_TO"
	assert_contains "$(mp_search 'subject:"Backup Successful"')" '"Attachments":0' "the notice carries no attachment"

	# A login over plain SMTP, as a local relay with authentication takes it.
	fresh
	# shellcheck disable=SC2086
	env $mail_env SMTP_SECURITY=off SMTP_USERNAME=user SMTP_PASSWORD=secret sh /backup.sh local >/dev/null 2>&1
	assert_status $? 0 "local backup with a notice over authenticated plain SMTP succeeds"
	assert_eq "$(mp_total)" 1 "the notice arrives after AUTH"

	# starttls to a server that offers no STARTTLS must not fall back to plain:
	# that is what a stripped STARTTLS looks like. The backup itself succeeds;
	# the mail is refused and logged.
	fresh
	# shellcheck disable=SC2086
	out=$(env $mail_env SMTP_SECURITY=starttls SMTP_USERNAME=user SMTP_PASSWORD=secret sh /backup.sh local 2>&1)
	assert_status $? 0 "a backup still succeeds when the notice cannot be sent"
	assert_contains "$out" "Email error" "starttls to a server without STARTTLS is reported"
	assert_eq "$(mp_total)" 0 "starttls to a server without STARTTLS sends nothing in clear"

	# A failure mail is delivered, not just handed to mutt.
	fresh
	# shellcheck disable=SC2086
	env $mail_env SMTP_SECURITY=off SMTP_USERNAME= SMTP_PASSWORD= sh /backup.sh bogus >/dev/null 2>&1
	assert_eq "$(mp_total)" 1 "an invalid method sends one failure mail"
	assert_contains "$(mp_search 'subject:"Backup Failed"')" '"Subject":"Test - Backup Failed"' "the failure mail has the failure subject"

	# BACKUP_EMAIL_NOTIFY_ON_FAILURE_ONLY: nothing on success, still mail on failure.
	fresh
	# shellcheck disable=SC2086
	env $mail_env SMTP_SECURITY=off SMTP_USERNAME= SMTP_PASSWORD= BACKUP_EMAIL_NOTIFY_ON_FAILURE_ONLY=true sh /backup.sh local >/dev/null 2>&1
	assert_status $? 0 "local backup with failure-only notifications succeeds"
	assert_eq "$(mp_total)" 0 "failure-only: a success sends nothing"
	rm -f /tmp/muttrc
	# shellcheck disable=SC2086
	env $mail_env SMTP_SECURITY=off SMTP_USERNAME= SMTP_PASSWORD= BACKUP_EMAIL_NOTIFY_ON_FAILURE_ONLY=true sh /backup.sh bogus >/dev/null 2>&1
	assert_eq "$(mp_total)" 1 "failure-only: a failure still sends its mail"

	mp_clear
	rm -f /tmp/muttrc
else
	printf '  skip SMTP delivery (BWGC_SMTP_HOST and BWGC_MAILPIT_API not set)\n'
fi
