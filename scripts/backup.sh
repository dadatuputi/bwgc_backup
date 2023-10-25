#!/usr/bin/env ash

# vaultwarden backup script for docker
# Copyright (C) 2021 Bradford Law
# Licensed under the terms of MIT

LOG=/var/log/backup.log
MUTTRC=/tmp/muttrc

# Bitwarden Email settings - usually provided as environment variables for but may be set below:
# SMTP_HOST=
# SMTP_FROM=
# SMTP_PORT=
# SMTP_SECURITY=
# SMTP_USERNAME=
# SMTP_PASSWORD
AUTH_METHOD=LOGIN

# Backup settings - provided as environment variables but may be set below:
# SMTP_FROM_NAME=
# BACKUP_EMAIL_TO=


# Initialize e-mail if (using e-mail backup OR BACKUP_EMAIL_NOTIFY is set) AND ssmtp has not been configured
if [ "$1" == "email" -o "$BACKUP_EMAIL_NOTIFY" == "true" ] && [ ! -f "$MUTTRC" ]; then
  if [ "$SMTP_SECURITY" == "force_tls" ]; then
    MUTT_SSL_KEY=ssl_force_tls
    SMTP_PROTO=smtps
  else
    MUTT_SSL_KEY=ssl_starttls
    SMTP_PROTO=smtp
  fi
  cat >"$MUTTRC" <<EOF
set ${MUTT_SSL_KEY}=yes
set smtp_url="${SMTP_PROTO}://${SMTP_USERNAME}@${SMTP_HOST}:${SMTP_PORT}"
set smtp_pass="${SMTP_PASSWORD}"
EOF
  printf "Finished configuring email.\n" >$LOG
fi


# Send an email
# $1: subject
# $2: body
# $3: attachment
email_send() {
  if [ -n "$3" ]; then
    ATTACHMENT="-a $3 --"
  else 
    ATTACHMENT=""
  fi

  if EMAIL_RESULT=$(printf "$2" | EMAIL="$SMTP_FROM_NAME <$SMTP_FROM>" mutt -F "$MUTTRC" -s "$1" $ATTACHMENT "$BACKUP_EMAIL_TO" 2>&1); then
    printf "Sent e-mail (%b) to %b\n" "$1" "$BACKUP_EMAIL_TO" >> $LOG
  else
    printf "Email error: %b\n" "$EMAIL_RESULT" >> $LOG
  fi
}


# Build email body message
# Print instructions to untar and unencrypt as needed
# $1: backup filename
email_body() {
  EXT=${1##*.}
  FILE=${1%%.*}

  # Email body messages
  EMAIL_BODY_TAR="Email backup successful.

To restore, untar in the Bitwarden data directory:
    tar -zxf $FILE.tar.gz"

  EMAIL_BODY_AES="To decrypt an encrypted backup (.aes256), first decrypt using openssl:
    openssl enc -d -aes256 -salt -pbkdf2 -pass pass:<password> -in $FILE.tar.gz.aes256 -out $FILE.tar.gz"


  BODY=$EMAIL_BODY_TAR
  [ "$EXT" == "aes256" ] && BODY="$BODY\n\n $EMAIL_BODY_AES"

  printf "$BODY"
}


# Initialize rclone
RCLONE=/usr/bin/rclone
rclone_init() {
  # Install rclone - https://wiki.alpinelinux.org/wiki/Rclone
  # rclone install now handled in Dockerfile, so this function should never be executed
  curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip
  unzip rclone-current-linux-amd64.zip
  cd rclone-*-linux-amd64
  cp rclone /usr/bin/
  chown root:root $RCLONE
  chmod 755 $RCLONE

  printf "Rclone installed to %b\n" "$RCLONE" >> $LOG
}


# Create backup and prune old backups
# Borrowed heavily from https://github.com/shivpatel/bitwarden_rs-local-backup
# with the addition of backing up:
# * attachments directory
# * sends directory
# * config.json
# * rsa_key* files
make_backup() {
  # use sqlite3 to create backup (avoids corruption if db write in progress)
  SQL_NAME="db.sqlite3"
  SQL_BACKUP_DIR="/tmp"
  SQL_BACKUP_NAME=$SQL_BACKUP_DIR/$SQL_NAME
  sqlite3 /data/$SQL_NAME ".backup '$SQL_BACKUP_NAME'"

  # build a string of files and directories to back up
  cd /
  DATA="data"
  FILES=""
  FILES="$FILES $([ -d $DATA/attachments ] && echo $DATA/attachments)"
  FILES="$FILES $([ -d $DATA/sends ] && echo $DATA/sends)"
  FILES="$FILES $([ -r $DATA/config.json ] && echo $DATA/config.json)"
  FILES="$FILES $([ -r $DATA/rsa_key.der -o -r $DATA/rsa_key.pem -o -r $DATA/rsa_key.pub.der ] && echo $DATA/rsa_key*)"

  FILES="$FILES $([ -r .env ] && [ "$BACKUP_ENV" == "true" ] && echo .env)"

  # tar up files and encrypt with openssl and encryption key
  BACKUP_DIR=/$DATA/backups
  BACKUP_FILE=$BACKUP_DIR/"bw_backup_$(date "+%F-%H%M%S").tar.gz"

  # If a password is provided, run it through openssl
  if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
    BACKUP_FILE=$BACKUP_FILE.aes256
    tar czf - -C / $FILES -C $SQL_BACKUP_DIR $SQL_NAME | openssl enc -e -aes256 -salt -pbkdf2 -pass pass:${BACKUP_ENCRYPTION_KEY} -out $BACKUP_FILE
  else
    tar czf $BACKUP_FILE -C / $FILES -C $SQL_BACKUP_DIR $SQL_NAME
  fi
  printf "Backup file created at %b\n" "$BACKUP_FILE" >> $LOG

  # cleanup tmp folder
  rm -f $SQL_BACKUP_NAME

  # rm any backups older than 30 days
  find $BACKUP_DIR/* -mtime +$BACKUP_DAYS -exec rm {} \;

  printf "$BACKUP_FILE"
}


##############################################################################################
# Main Backup 

backup(){
  
  METHOD=$1
  RESULT=$2
  case $METHOD in
    local)
      printf "Running local backup\n" >> $LOG
      if [ "$BACKUP_EMAIL_NOTIFY" == "true" ]; then
        email_send "$SMTP_FROM_NAME - local backup completed" "Local backup completed"
      fi

      ;;
    email)
      # Handle E-mail Backup
      printf "Running email backup\n" >> $LOG
      # Backup and send e-mail
      FILENAME=$(basename $RESULT)
      BODY=$(email_body $FILENAME)
      email_send "$SMTP_FROM_NAME - $FILENAME" "$BODY" $RESULT
      ;;

    rclone)
      # Handle rclone Backup
      printf "Running rclone backup\n" >> $LOG
      # Initialize rclone if BACKUP=rclone and $(which rclone) is blank
      if [ "$1" == "rclone" -a -z "$(which rclone)" ]; then
        rclone_init
      fi

      # Only run if $BACKUP_RCLONE_CONF has been setup
      if [ -s "$BACKUP_RCLONE_CONF" ]; then
        # Sync with rclone
        REMOTE=$(rclone --config $BACKUP_RCLONE_CONF listremotes | head -n 1)
        ERR=$(rclone --config $BACKUP_RCLONE_CONF sync $BACKUP_DIR "$REMOTE$BACKUP_RCLONE_DEST" 2>&1)
        SYNC_STATUS=$?

        if [ $SYNC_STATUS -ne 0 ]; then
          printf "Failed to sync:\n  %b\n" "$ERR" >> $LOG
        fi

        # Send email if configured
        if [ "$BACKUP_EMAIL_NOTIFY" == "true" ]; then
          if [ $SYNC_STATUS -eq 0 ]; then
            email_send "$SMTP_FROM_NAME - rclone backup completed" "Rclone backup completed"
          else
            email_send "$SMTP_FROM_NAME - rclone backup failed" "$ERR"
          fi
        fi
      fi
      ;;

  esac

}


##############################################################################################



VALID="local email rclone"
printf "Running backup to: %b\n" "$1" >> $LOG

for METHOD in ${1//,/ }
do
  # check if provided backup method is valid
  if echo $VALID | grep -q -w "$METHOD"; then 
    if [ ! -n "$RESULT" ]; then
      RESULT=$(make_backup)
    fi
    backup $METHOD $RESULT
  else
    printf "Bad backup method provided: %b\n" "$METHOD" >> $LOG
  fi
done
