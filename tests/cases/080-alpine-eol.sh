# The image pins an Alpine branch, so something has to say when that branch
# leaves support. Fixtures are served over file:// so the test does not depend
# on the network or on today's real dates.
reset_data
unset BACKUP_ENCRYPTION_KEY 2>/dev/null || true
sh /backup.sh local >/dev/null 2>&1

BRANCH="v$(. /etc/os-release; printf '%s' "$VERSION_ID" | cut -d. -f1,2)"
mk_fixture() {
	printf '{"release_branches":[{"branch_date":"2020-01-01","rel_branch":"v3.1","releases":[{"version":"3.1.0"}],"eol_date":"2021-01-01"},{"branch_date":"2026-01-01","rel_branch":"%s","releases":[{"version":"x"},{"version":"y"}],"eol_date":"%s"}]}' "$BRANCH" "$1" > /tmp/rel.json
}

mk_fixture "2099-01-01"
OUT=$(BACKUP_EMAIL_NOTIFY=false METADATA_HOST=169.254.255.255 ALPINE_RELEASES_URL=file:///tmp/rel.json sh /backup.sh check 2>&1); STATUS=$?
assert_status "$STATUS" 0 "a far-future EOL is not a problem"
assert_contains "$OUT" "supported until 2099-01-01" "reports the branch EOL date"

mk_fixture "2000-01-01"
OUT=$(BACKUP_EMAIL_NOTIFY=false METADATA_HOST=169.254.255.255 ALPINE_RELEASES_URL=file:///tmp/rel.json sh /backup.sh check 2>&1); STATUS=$?
assert_status "$STATUS" 1 "an expired branch fails the check"
assert_contains "$OUT" "left support on 2000-01-01" "names the date support ended"

# Picks the right branch out of a file containing several.
assert_not_contains "$OUT" "2021-01-01" "does not pick up another branch's date"

# An unreachable feed must degrade, not fail the check.
OUT=$(BACKUP_EMAIL_NOTIFY=false METADATA_HOST=169.254.255.255 ALPINE_RELEASES_URL=file:///nonexistent sh /backup.sh check 2>&1); STATUS=$?
assert_status "$STATUS" 0 "an unreachable releases feed is not treated as a failure"
