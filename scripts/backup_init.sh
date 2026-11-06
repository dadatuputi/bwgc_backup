#! /bin/sh

LOG=/var/log/backup.log

# If BACKUP is set, put the backup script in crontab

if [ -n "$BACKUP" ]; then
  # Validate BACKUP_SCHEDULE before appending it to the crontab.
  #
  # Two reasons. This is a plain append, so a value containing a newline
  # injects arbitrary crontab lines. And a malformed expression produces a line
  # cron silently ignores, which is the failure mode that lets backups stop
  # without anyone noticing -- one deployment ran eight months that way.
  if [ -z "$BACKUP_SCHEDULE" ]; then
    printf "ERROR: BACKUP_SCHEDULE is empty; refusing to start\n" >> $LOG
    printf "ERROR: BACKUP_SCHEDULE is empty; refusing to start\n" >&2
    exit 1
  fi
  if [ "$(printf '%s' "$BACKUP_SCHEDULE" | wc -l)" -ne 0 ]; then
    printf "ERROR: BACKUP_SCHEDULE contains a newline; refusing to start\n" >> $LOG
    printf "ERROR: BACKUP_SCHEDULE contains a newline; refusing to start\n" >&2
    exit 1
  fi
  if [ "$(printf '%s' "$BACKUP_SCHEDULE" | wc -w)" -ne 5 ]; then
    printf "ERROR: BACKUP_SCHEDULE needs exactly 5 fields, got: %s\n" "$BACKUP_SCHEDULE" >> $LOG
    printf "ERROR: BACKUP_SCHEDULE needs exactly 5 fields, got: %s\n" "$BACKUP_SCHEDULE" >&2
    exit 1
  fi
  case "$BACKUP_SCHEDULE" in
    *[!0-9*,/\ ---]*)
      printf "ERROR: BACKUP_SCHEDULE has unexpected characters: %s\n" "$BACKUP_SCHEDULE" >> $LOG
      printf "ERROR: BACKUP_SCHEDULE has unexpected characters: %s\n" "$BACKUP_SCHEDULE" >&2
      exit 1
      ;;
  esac

  sed -i "/ash \\/backup\\.sh /d" /etc/crontabs/root
  printf "Removing any existing crontab entries for backup.sh\n" >> $LOG
  echo "$BACKUP_SCHEDULE ash /backup.sh $BACKUP" >> /etc/crontabs/root
  printf "Adding backup.sh crontab entry (%b)\n" "$BACKUP_SCHEDULE" >> $LOG
  # Weekly status check: is the host OS milestone still supported, and has a
  # backup actually run recently? Both fail silently by default, which is why
  # they are checked rather than assumed.
  CHECK_SCHEDULE="${CHECK_SCHEDULE:-0 6 * * 1}"
  if [ "$CHECK_SCHEDULE" != "disabled" ]; then
    sed -i "/ash \\/backup\\.sh check/d" /etc/crontabs/root
    echo "$CHECK_SCHEDULE ash /backup.sh check" >> /etc/crontabs/root
    printf "Adding status check crontab entry (%b)\n" "$CHECK_SCHEDULE" >> $LOG
  fi

  printf "Starting the cron daemon\n" >> $LOG

  # crond runs in the foreground, watched by this shell. Two things the old
  # "crond -d 8; tail -f /dev/null" got wrong:
  #   - if crond died, the container kept running with no scheduler, so
  #     backups stopped and nothing restarted it. Now the container exits
  #     with crond's status and the restart policy brings it back.
  #   - PID 1 ignores SIGTERM unless it traps it, so every "docker stop"
  #     (each Watchtower update) waited 10 seconds and then SIGKILLed the
  #     container. A backup still running when the container stops is cut
  #     off either way; backup.sh writes under a temporary name, so it
  #     leaves no truncated archive behind.
  crond -f -d 8 &
  CROND=$!
  trap 'kill -TERM "$CROND" 2>/dev/null; wait "$CROND"; exit 0' TERM INT
  wait "$CROND"
  STATUS=$?
  printf "The cron daemon exited (status %s); stopping the container\n" "$STATUS" >> $LOG
  exit "$STATUS"

else
  printf "Backup is not configured, exiting\n" >> $LOG
fi

