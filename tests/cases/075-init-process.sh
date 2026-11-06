# backup_init.sh stays in the foreground watching crond: a stop request ends
# it at once, and a crond that dies takes the container down with it so the
# restart policy can bring it back.
cp /etc/crontabs/root /tmp/crontab.saved

BACKUP=local BACKUP_SCHEDULE="0 0 * * *" CHECK_SCHEDULE=disabled sh /backup_init.sh >/dev/null 2>&1 &
INIT=$!
sleep 1
pgrep crond >/dev/null && pass "crond is running" || fail "crond is running"
kill -TERM "$INIT"
# Give it two seconds; a shell that ignored TERM would still be running.
i=0
while kill -0 "$INIT" 2>/dev/null && [ $i -lt 20 ]; do sleep 0.1; i=$((i+1)); done
kill -0 "$INIT" 2>/dev/null && fail "SIGTERM stops it promptly" || pass "SIGTERM stops it promptly"
wait "$INIT"; STATUS=$?
assert_status "$STATUS" 0 "a requested stop exits 0"
pgrep crond >/dev/null && fail "crond is stopped with it" || pass "crond is stopped with it"

BACKUP=local BACKUP_SCHEDULE="0 0 * * *" CHECK_SCHEDULE=disabled sh /backup_init.sh >/dev/null 2>&1 &
INIT=$!
sleep 1
pkill -KILL crond
wait "$INIT"; STATUS=$?
assert_ne "$STATUS" 0 "a dead crond ends it with a failure status, so the container restarts"

cp /tmp/crontab.saved /etc/crontabs/root
