#!/usr/bin/env sh
#
# Test suite for bwgc_backup.
#
#   ./tests/run-tests.sh            build the image and run every case
#   ./tests/run-tests.sh restore    run only cases matching "restore"
#   BWGC_IMAGE=... ./tests/run-tests.sh    test an existing image instead
#
# These run INSIDE the image, because what is being tested is the interaction
# between the script and the tools it depends on -- sqlite3, openssl, tar,
# docker-cli -- and mocking those would test the mocks.
#
# The container is given no Docker socket on purpose: that is the state in
# which restore must refuse to run.

set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FILTER="${1:-}"

if [ -n "${BWGC_IMAGE:-}" ]; then
	IMAGE="$BWGC_IMAGE"
	printf 'testing existing image: %s\n' "$IMAGE"
else
	IMAGE=bwgc_backup:test
	printf 'building %s\n' "$IMAGE"
	docker build -q -t "$IMAGE" "$ROOT" >/dev/null
fi

# BWGC_SMTP_HOST, BWGC_SMTP_PORT and BWGC_MAILPIT_API point the delivery case
# at a mailpit server; unset, that case skips. host.docker.internal lets a
# server on this host be named from inside the container.
docker run --rm \
	-e FILTER="$FILTER" \
	-e BWGC_SMTP_HOST="${BWGC_SMTP_HOST:-}" \
	-e BWGC_SMTP_PORT="${BWGC_SMTP_PORT:-}" \
	-e BWGC_MAILPIT_API="${BWGC_MAILPIT_API:-}" \
	--add-host=host.docker.internal:host-gateway \
	-v "$ROOT/tests:/tests:ro" \
	-v "$ROOT/scripts/backup.sh:/backup.sh:ro" \
	-v "$ROOT/scripts/backup_init.sh:/backup_init.sh:ro" \
	--entrypoint sh "$IMAGE" /tests/in-container.sh
