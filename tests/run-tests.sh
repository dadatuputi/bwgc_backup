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
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FILTER="${1:-}"

if [ -n "${BWGC_IMAGE:-}" ]; then
	IMAGE="$BWGC_IMAGE"
	printf 'testing existing image: %s\n' "$IMAGE"
else
	IMAGE=bwgc_backup:test
	printf 'building %s\n' "$IMAGE"
	docker build -q -t "$IMAGE" "$ROOT" >/dev/null
fi

docker run --rm \
	-e FILTER="$FILTER" \
	-v "$ROOT/tests:/tests:ro" \
	-v "$ROOT/scripts/backup.sh:/backup.sh:ro" \
	-v "$ROOT/scripts/backup_init.sh:/backup_init.sh:ro" \
	--entrypoint sh "$IMAGE" /tests/in-container.sh
