# The encrypted path must round-trip, and the key must not reach argv.
reset_data
# A throwaway fixture, not a credential. Chosen to contain a space, a double
# quote and a dollar sign, because the previous -pass pass:$VAR form was
# unquoted and broke outright on exactly these characters.
export BACKUP_ENCRYPTION_KEY='fixture-only p a s s"w0rd$with spaces'
sh /backup.sh local >/dev/null 2>&1
ARCHIVE=$(ls -t /data/backups/bw_backup_*.aes256 2>/dev/null | head -1)
assert_file "$ARCHIVE" "encrypted archive written"

# A key containing spaces and metacharacters must survive. Unquoted -pass pass:
# used to break outright on exactly this.
LIST=$(BW_KEY="$BACKUP_ENCRYPTION_KEY" openssl enc -d -aes256 -salt -pbkdf2 -pass env:BW_KEY -in "$ARCHIVE" 2>/dev/null | tar tzf - 2>/dev/null)
assert_contains "$LIST" "db.sqlite3" "archive with an awkward key still decrypts"

assert_not_contains "$(cat /backup.sh)" 'pass:$'   "source never passes a key as pass:\$VAR"
assert_not_contains "$(cat /backup.sh)" 'pass:"$'  "source never passes a key as pass:\"\$VAR\""
assert_contains "$(cat /backup.sh)" 'pass env:BW_KEY' "source uses -pass env:"
unset BACKUP_ENCRYPTION_KEY
