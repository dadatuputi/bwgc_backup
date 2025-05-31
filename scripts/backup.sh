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

###### E-mail Functions ######################################################################

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

###### Backup Functions ######################################################################

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
        REMOTES=$(rclone --config $BACKUP_RCLONE_CONF listremotes | tr '\n' ' ')
        SYNC_TOTAL_CNT=0
        SYNC_FAILED_CNT=0
        for REMOTE in $REMOTES
        do
          SYNC_TOTAL_CNT=$(($SYNC_TOTAL_CNT + 1))
          SYNC_LOG_ITEM="$(rclone --config $BACKUP_RCLONE_CONF sync $BACKUP_DIR "$REMOTE$BACKUP_RCLONE_DEST" 2>&1)"
          if [ $? -ne 0 ]; then
            SYNC_ERROR_LOG="${SYNC_ERROR_LOG}Sync log with ${REMOTE}\n==========\n${SYNC_LOG_ITEM}\n==========\n\n"
            SYNC_FAILED_CNT=$(($SYNC_FAILED_CNT + 1))
          fi
        done

        if [ $SYNC_FAILED_CNT -ne 0 ]; then
          printf "Failed to sync to ${SYNC_FAILED_CNT} of ${SYNC_TOTAL_CNT} remotes:\n  %b\n" "$SYNC_ERROR_LOG" >> $LOG
        fi

        # Send email if configured
        if [ "$BACKUP_EMAIL_NOTIFY" == "true" ]; then
          if [ $SYNC_FAILED_CNT -eq 0 ]; then
            email_send "$SMTP_FROM_NAME - rclone backup completed" "Rclone backup completed to ${SYNC_TOTAL_CNT} remotes"
          else
            email_send "$SMTP_FROM_NAME - rclone backup failed to ${SYNC_FAILED_CNT} of ${SYNC_TOTAL_CNT} remotes" "$SYNC_ERROR_LOG"
          fi
        fi
      fi
      ;;

  esac

}

###### Restore ###############################################################################

# Function to stop the bitwarden container
stop_bitwarden() {
  printf "Stopping vaultwarden container...\n" >> $LOG
  if ! docker stop bitwarden > /dev/null; then
    printf "Warning: Could not stop bitwarden container. Restoration may fail if database is in use.\n" >> $LOG
    return 1
  fi
  return 0
}

# Function to start the bitwarden container
start_bitwarden() {
  printf "Starting vaultwarden container...\n" >> $LOG
  if ! docker start bitwarden > /dev/null; then
    printf "Warning: Could not start bitwarden container. You may need to start it manually.\n" >> $LOG
    return 1
  fi
  return 0
}

# Restore a backup file
# $1: path to backup file
restore_backup() {
  BACKUP_FILE=$1
  
  if [ ! -f "$BACKUP_FILE" ]; then
    printf "Error: Backup file %s not found.\n" "$BACKUP_FILE" >&2
    exit 1
  fi
  
  printf "Attempting to restore from %s\n" "$BACKUP_FILE" >> $LOG
  
  # Create a temporary directory for extraction
  RESTORE_TMP_DIR=$(mktemp -d)
  
  # Check if this is an encrypted backup
  if [ "${BACKUP_FILE%.aes256}" != "$BACKUP_FILE" ]; then
    printf "Detected encrypted backup file.\n" >> $LOG
    
    # Check for decryption key in environment variables first
    if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
      DECRYPT_KEY="$BACKUP_ENCRYPTION_KEY"
      printf "Using encryption key from environment variable.\n" >> $LOG
    else
      # No key in environment, try interactive prompt
      if [ -t 0 ]; then
        printf "Enter decryption key: "
        read -r -s DECRYPT_KEY
        echo # Add newline after password input
        
        # Verify key was entered
        if [ -z "$DECRYPT_KEY" ]; then
          printf "Error: No decryption key provided.\n" >&2
          rm -rf "$RESTORE_TMP_DIR"
          exit 1
        fi
      else
        printf "Error: No encryption key available. Cannot prompt in non-interactive mode.\n" >&2
        printf "Please provide the key via BACKUP_ENCRYPTION_KEY environment variable.\n" >&2
        rm -rf "$RESTORE_TMP_DIR"
        exit 1
      fi
    fi
    
    # Decrypt and extract
    printf "Decrypting backup file...\n" >> $LOG
    if ! openssl enc -d -aes256 -salt -pbkdf2 -pass pass:"${DECRYPT_KEY}" -in "$BACKUP_FILE" | tar xzf - -C "$RESTORE_TMP_DIR"; then
      printf "Error: Failed to decrypt or extract the backup file.\n" >&2
      rm -rf "$RESTORE_TMP_DIR"
      exit 1
    fi
  else
    # Extract unencrypted backup
    printf "Extracting backup file...\n" >> $LOG
    if ! tar xzf "$BACKUP_FILE" -C "$RESTORE_TMP_DIR"; then
      printf "Error: Failed to extract the backup file.\n" >&2
      rm -rf "$RESTORE_TMP_DIR"
      exit 1
    fi
  fi
  
  # Create backup using existing local backup function
  printf "Creating backup of current state before restoration...\n" >> $LOG
  make_backup
  
  # Stop the bitwarden container before restoration
  BITWARDEN_STOPPED=0
  if command -v docker >/dev/null 2>&1; then
    if stop_bitwarden; then
      BITWARDEN_STOPPED=1
    fi
  else
    printf "Docker command not found. Cannot stop/start bitwarden container.\n" >> $LOG
    printf "Docker command not found. Please stop the bitwarden container manually before continuing.\n"
    printf "Run: docker stop bitwarden\n"
    printf "And after restore completes: docker start bitwarden\n"
  fi
  
  # Create a timestamp for backup files
  TIMESTAMP=$(date "+%F-%H%M%S")
  
  # Restore the SQLite database
  if [ -f "$RESTORE_TMP_DIR/db.sqlite3" ]; then
    printf "Restoring database...\n" >> $LOG
    if [ -f "/data/db.sqlite3" ]; then
      rm -f "/data/db.sqlite3"
    fi
    
    # Restore the database
    cp "$RESTORE_TMP_DIR/db.sqlite3" "/data/db.sqlite3"
    RET_CODE=$?
    if [ $RET_CODE -ne 0 ]; then
      printf "Error: Failed to restore database.\n" >&2
    else
      printf "Database restored successfully.\n" >> $LOG
      # Set correct permissions for db file
      chmod 644 "/data/db.sqlite3" || true
    fi
  else
    printf "Warning: Could not find database in backup.\n" >> $LOG
  fi
  
  # Restore other files and directories
  printf "Restoring data files...\n" >> $LOG
  
  # Restore attachments
  if [ -d "$RESTORE_TMP_DIR/data/attachments" ]; then
    if [ -d "/data/attachments" ]; then
      rm -rf "/data/attachments"
    fi
    cp -r "$RESTORE_TMP_DIR/data/attachments" "/data/" || printf "Failed to restore attachments.\n" >> $LOG
  fi
  
  # Restore sends
  if [ -d "$RESTORE_TMP_DIR/data/sends" ]; then
    if [ -d "/data/sends" ]; then
      rm -rf "/data/sends"
    fi
    cp -r "$RESTORE_TMP_DIR/data/sends" "/data/" || printf "Failed to restore sends.\n" >> $LOG
  fi
  
  # Restore config.json
  if [ -f "$RESTORE_TMP_DIR/data/config.json" ]; then
    if [ -f "/data/config.json" ]; then
      rm -f "/data/config.json"
    fi
    cp "$RESTORE_TMP_DIR/data/config.json" "/data/" || printf "Failed to restore config.json.\n" >> $LOG
  fi
  
  # Restore RSA keys
  if [ -d "$RESTORE_TMP_DIR/data" ]; then
    # Use find instead of bash glob expansion
    find "$RESTORE_TMP_DIR/data" -name "rsa_key*" -type f | while read -r key_file; do
      if [ -f "$key_file" ]; then
        KEY_FILENAME=$(basename "$key_file")
        if [ -f "/data/$KEY_FILENAME" ]; then
          rm -f "/data/$KEY_FILENAME"
        fi
        cp "$key_file" "/data/" || printf "Failed to restore %s.\n" "$KEY_FILENAME" >> $LOG
      fi
    done
  fi
    
  # Restore .env file if it was backed up
  if [ -f "$RESTORE_TMP_DIR/.env" ] && [ "$BACKUP_ENV" = "true" ]; then
    # Copy to a location that's accessible but won't cause conflicts
    cp "$RESTORE_TMP_DIR/.env" "/data/.env.restored" || printf "Failed to copy .env to reference location.\n" >> $LOG
    
    # Print detailed instructions for the user
    INSTRUCTIONS="
    ---------------------------------------------------------------------------------
    IMPORTANT: .ENV FILE NOTICE
    ---------------------------------------------------------------------------------
    
    The .env file cannot be automatically restored while Docker Compose is running.
    A copy of the restored .env file has been placed at:
      bitwarden/.env.restored
    
    To complete the restoration process manually:
    
    1. Review the differences between your current .env and the restored version:
       diff .env bitwarden/.env.restored
    
    2. To fully apply the restored .env:
       a. Stop all services: docker-compose down
       b. Replace your .env file: cp bitwarden/.env.restored .env
       c. Restart services: docker-compose up -d
    
    NOTE: Only do this if you want to completely replace your current environment settings!
    ---------------------------------------------------------------------------------"
    
    printf "%s\n" "$INSTRUCTIONS" >> $LOG
    printf "%s\n" "$INSTRUCTIONS"
  fi
  
  # Clean up
  rm -rf "$RESTORE_TMP_DIR"
  
  # Restart bitwarden container if we stopped it
  if [ "$BITWARDEN_STOPPED" -eq 1 ] && command -v docker >/dev/null 2>&1; then
    start_bitwarden
  fi
  
  printf "Restore completed.\n" >> $LOG
  printf "Restore completed successfully.\n"
}

###### Main Execution ########################################################################

case "$1" in
  restore)
    if [ -z "$2" ]; then
      printf "Error: No backup file specified.\n" >&2
      printf "Usage: $0 restore <backup_file>\n" >&2
      exit 1
    fi
    restore_backup "$2"
    ;;
  local|email|rclone)
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
    ;;
  *)
    printf "Usage: $0 {local|email|rclone|restore <backup_file>}\n" >&2
    exit 1
    ;;
esac
