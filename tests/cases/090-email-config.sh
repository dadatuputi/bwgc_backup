# The mutt configuration follows SMTP_SECURITY and SMTP_USERNAME. check runs the
# e-mail setup first; with a fresh backup it has nothing to send.
reset_data
unset BACKUP_ENCRYPTION_KEY 2>/dev/null || true
sh /backup.sh local >/dev/null 2>&1
muttrc() {
	rm -f /tmp/muttrc
	env SMTP_HOST=mail.example.com SMTP_PORT=587 BACKUP_EMAIL_NOTIFY=true METADATA_HOST=169.254.255.255 "$@" \
		sh /backup.sh check >/dev/null 2>&1
	cat /tmp/muttrc
}

RC=$(muttrc SMTP_SECURITY=starttls SMTP_USERNAME=user SMTP_PASSWORD=secret)
assert_contains "$RC" "set ssl_force_tls=yes"                           "starttls: TLS required"
assert_contains "$RC" "set ssl_starttls=yes"                            "starttls: through STARTTLS"
assert_contains "$RC" 'set smtp_url="smtp://user@mail.example.com:587"' "starttls: smtp URL with the user"
assert_contains "$RC" 'set smtp_pass="secret"'                          "starttls: password set"

RC=$(muttrc SMTP_SECURITY=force_tls SMTP_USERNAME=user SMTP_PASSWORD=secret)
assert_contains "$RC" "set ssl_force_tls=yes"                           "force_tls: TLS required"
assert_contains "$RC" 'set smtp_url="smtps://user@mail.example.com:587"' "force_tls: smtps URL"

RC=$(muttrc SMTP_SECURITY=off SMTP_USERNAME=user SMTP_PASSWORD=secret)
assert_contains "$RC" "set ssl_force_tls=no"                            "off: TLS not required"
assert_contains "$RC" "set ssl_starttls=no"                             "off: no STARTTLS attempt"

RC=$(muttrc SMTP_SECURITY=off SMTP_USERNAME= SMTP_PASSWORD=)
assert_contains "$RC" 'set smtp_url="smtp://mail.example.com:587"'      "no user: URL without a login"
assert_not_contains "$RC" "smtp_pass"                                   "no user: no password line"

RC=$(muttrc SMTP_SECURITY= SMTP_USERNAME=user SMTP_PASSWORD=secret)
assert_contains "$RC" "set ssl_force_tls=yes"                           "unset security: TLS required, as starttls"
