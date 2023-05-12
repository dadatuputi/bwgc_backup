#! /bin/sh

LOG=/var/log/backup.log

# If BACKUP is set, put the backup script in crontab

if [ -n "$BACKUP" ]; then
  sed -i "/ash \\/backup\\.sh /d" /etc/crontabs/root
  printf "Removing any existing crontab entries for backup.sh\n" >> $LOG
  echo "$BACKUP_SCHEDULE ash /backup.sh $BACKUP" >> /etc/crontabs/root
  printf "Adding backup.sh crontab entry (%b)\n" "$BACKUP_SCHEDULE" >> $LOG
  crond -d 8;
  printf "Starting the cron daemon\n" >> $LOG

  # Sleep indefinitely
  tail -f /dev/null

else
  printf "Backup is not configured, exiting\n" >> $LOG
fi

