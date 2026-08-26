#!/usr/bin/env sh
# Runs inside the image. Executes every case file and reports.
set -u
. /tests/lib-assert.sh

printf '\nbwgc_backup tests (alpine %s)\n\n' "$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-?}")"

for case_file in /tests/cases/*.sh; do
	name=$(basename "$case_file" .sh)
	if [ -n "${FILTER:-}" ]; then
		case "$name" in *"$FILTER"*) ;; *) continue ;; esac
	fi
	printf '%s\n' "$name"
	# shellcheck disable=SC1090
	. "$case_file"
	printf '\n'
done

printf 'ran %d assertions, %d failed\n\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
