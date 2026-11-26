# The OS update check compares the host's last restart with the newest build of
# its milestone. Metadata and the Compute API are served from files.
reset_data
sh /backup.sh local >/dev/null 2>&1
FX=/tmp/os-fixtures
rm -rf "$FX"; mkdir -p "$FX/md/instance/service-accounts/default" "$FX/api/projects/cos-cloud/global/images/family"
printf 'projects/cos-cloud/global/images/cos-133-19999-44-85' > "$FX/md/instance/image"
printf '{"access_token":"t","expires_in":3599}' > "$FX/md/instance/service-accounts/default/token"
NOW=$(date +%s)

# Google writes creation times in Pacific time with milliseconds.
newest_built() {
	_local=$(date -u -d @$((NOW - $1 * 86400 - 28800)) +%Y-%m-%dT%H:%M:%S)
	cat > "$FX/api/projects/cos-cloud/global/images/family/cos-133-lts" <<JSON
{
  "kind": "compute#image",
  "id": "123",
  "creationTimestamp": "$_local.123-08:00",
  "name": "cos-133-19999-44-250",
  "family": "cos-133-lts",
  "guestOsFeatures": [{"type": "UEFI_COMPATIBLE"}]
}
JSON
}
up_days() { printf '%s.00 1.00\n' $(($1 * 86400)) > "$FX/uptime"; }
run_check() {
	BACKUP_EMAIL_NOTIFY=false METADATA_URL="file://$FX/md" COMPUTE_API="file://$FX/api" \
		PROC_UPTIME="$FX/uptime" sh /backup.sh check 2>&1
}

newest_built 10; up_days 30
OUT=$(run_check); STATUS=$?
assert_status "$STATUS" 1 "a host that has not restarted since a 10-day-old build fails"
assert_contains "$OUT" "OS updates are not reaching this host" "says updates are not arriving"
assert_contains "$OUT" "cos-133-19999-44-250, came out 10 days ago" "names the build and its age"
assert_contains "$OUT" "cos-update-strategy is unset" "shows the metadata key as a hint"

newest_built 10; up_days 2
OUT=$(run_check); STATUS=$?
assert_status "$STATUS" 0 "a host that restarted after the newest build passes"
assert_contains "$OUT" "OS updates are arriving" "says updates are arriving"
assert_not_contains "$OUT" "not reaching" "and raises nothing"

newest_built 3; up_days 30
OUT=$(run_check); STATUS=$?
assert_status "$STATUS" 0 "a build younger than a week is not yet expected"

rm "$FX/api/projects/cos-cloud/global/images/family/cos-133-lts"
OUT=$(run_check); STATUS=$?
assert_status "$STATUS" 0 "an unreachable Compute API does not raise an alert"
assert_contains "$OUT" "skipping the OS update check" "and says it skipped"
rm -rf "$FX"
