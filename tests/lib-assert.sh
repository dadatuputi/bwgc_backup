#!/usr/bin/env sh
# Minimal assertions, POSIX sh, no dependencies. Runs inside the image.

TESTS_RUN=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN+1)); printf '  ok   %s\n' "$1"; }
fail() {
	TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1))
	printf '  FAIL %s\n' "$1"
	[ -n "${2:-}" ] && printf '       %s\n' "$2"
	return 0
}
assert_eq() { [ "$1" = "$2" ] && pass "$3" || fail "$3" "expected '$2', got '$1'"; }
assert_ne() { [ "$1" != "$2" ] && pass "$3" || fail "$3" "expected something other than '$2'"; }
assert_file()    { [ -f "$1" ] && pass "$2" || fail "$2" "missing file: $1"; }
assert_no_file() { [ ! -e "$1" ] && pass "$2" || fail "$2" "file should not exist: $1"; }
assert_status()  { [ "$1" -eq "$2" ] && pass "$3" || fail "$3" "expected exit $2, got $1"; }
assert_contains() {
	printf '%s' "$1" | grep -qF -- "$2" && pass "$3" || fail "$3" "expected to find: $2"
}
assert_not_contains() {
	printf '%s' "$1" | grep -qF -- "$2" && fail "$3" "did not expect: $2" || pass "$3"
}

# Rebuild a clean /data for each case, so cases cannot leak into one another.
reset_data() {
	rm -rf /data
	mkdir -p /data/backups
	sqlite3 /data/db.sqlite3 "create table t(x); insert into t values(1);" 2>/dev/null
	mkdir -p /data/attachments /data/sends
	echo attachment > /data/attachments/file1
	printf 'key\n' > /data/rsa_key.der
	printf 'SMTP_HOST=example\n' > /.env
}

db_hash() { sha256sum /data/db.sqlite3 2>/dev/null | cut -c1-16; }
