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
# BACKUP_EMAIL_NOTIFY_ON_FAILURE_ONLY=

###### Utility Functions #####################################################################

# log
# Args:
#   $1 - MESSAGE: The log message text (string)
#   $2 - LEVEL: Optional log level (INFO|WARNING|ERROR). Defaults to INFO.
# Behavior:
#   Writes the message to stdout (INFO) or stderr (WARNING/ERROR) and
#   appends the same message to the file at $LOG.
# Returns:
#   Always returns 0 (used for side-effect logging).
log() {
  MESSAGE=$1
  LEVEL=${2:-INFO}

  # Build a single-line message and explicitly add newlines when printing
  MSG_PREFIX=$(printf "%s: %s" "$LEVEL" "$MESSAGE")

  case "$LEVEL" in
    ERROR|WARNING)
      # Errors and warnings should be visible on stderr
      printf '%s\n' "$MSG_PREFIX" >&2
      ;;
    *)
      # Informational messages go to stdout
      printf '%s\n' "$MSG_PREFIX"
      ;;
  esac

  printf '%s\n' "$MSG_PREFIX" >> "$LOG"
}

# log_error
# Args:
#   $1 - MESSAGE: The error message text.
# Behavior:
#   Convenience wrapper around log() that emits an ERROR-level message.
# Returns:
#   Same as log() (0) after emitting the message.
log_error() {
  log "$1" "ERROR"
}

###### E-mail Functions ######################################################################

# Initialize e-mail if (using e-mail backup OR BACKUP_EMAIL_NOTIFY is set) AND ssmtp has not been configured
if [ "$1" = "email" -o "$BACKUP_EMAIL_NOTIFY" = "true" ] && [ ! -f "$MUTTRC" ]; then
  if [ "$SMTP_SECURITY" = "force_tls" ]; then
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

# email_send
# Args:
#   $1 - SUBJECT: Subject line for the email
#   $2 - BODY: Email body text (can contain newlines and escapes)
#   $3 - ATTACHMENT: Optional path to an attachment file
# Behavior:
#   Sends an email using `mutt` configured via $MUTTRC. On success logs a sent message;
#   on failure logs an ERROR with the mutt output.
# Returns:
#   0 on success (mutt exit 0); non-zero on failure (mutt non-zero).
email_send() {
  SUBJECT=$1
  BODY=$2
  ATTACHMENT=$3

  if [ -n "$ATTACHMENT" ]; then
    ATTACHMENT="-a $ATTACHMENT --"
  else 
    ATTACHMENT=""
  fi

  if EMAIL_RESULT=$(printf '%b' "$BODY" | EMAIL="$SMTP_FROM_NAME <$SMTP_FROM>" mutt -F "$MUTTRC" -s "$SUBJECT" $ATTACHMENT "$BACKUP_EMAIL_TO" 2>&1); then
    log "$(printf "Sent e-mail (%b) to %b" "$SUBJECT" "$BACKUP_EMAIL_TO")"
  else
    log_error "$(printf "Email error: %b" "$EMAIL_RESULT")"
  fi
}



# email_body
# Args:
#   $1 - FILENAME: The backup filename (used to compute instructions for tar/openssl)
# Behavior:
#   Prints an email-friendly body describing how to restore/decrypt the provided backup.
# Returns:
#   Writes the generated body to stdout.
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
  [ "$EXT" = "aes256" ] && BODY="$BODY\n\n $EMAIL_BODY_AES"

  printf '%b' "$BODY"
}

###### Backup Functions ######################################################################


RCLONE=/usr/bin/rclone
# rclone_init
# Args:
#   None
# Behavior:
#   Installs `rclone` into $RCLONE (used only if rclone missing). Typically a no-op
#   because the Dockerfile installs rclone. Logs installation progress.
# Returns:
#   0 on success; non-zero on failure during installation.
rclone_init() {
  # Install rclone - https://wiki.alpinelinux.org/wiki/Rclone
  # rclone install now handled in Dockerfile, so this function should never be executed
  curl -O https://downloads.rclone.org/rclone-current-linux-amd64.zip
  unzip rclone-current-linux-amd64.zip
  cd rclone-*-linux-amd64
  cp rclone /usr/bin/
  chown root:root $RCLONE
  chmod 755 $RCLONE

  log "$(printf "Rclone installed to %b" "$RCLONE")"
}

# make_backup
# Create backup and prune old backups
# Borrowed heavily from https://github.com/shivpatel/bitwarden_rs-local-backup
# with the addition of backing up:
# * attachments directory
# * sends directory
# * config.json
# * rsa_key* files
# Args:
#   None
# Behavior:
#   Creates a compressed tarball of vaultwarden data (attachments, sends, config, rsa_key*, .env if enabled)
#   and a temporary sqlite3 backup. If BACKUP_ENCRYPTION_KEY is set the tarball is encrypted with openssl.
#   The created backup filename is printed to stdout on success.
# Returns:
#   0 on success (filename printed to stdout), non-zero on failure. Side-effects: writes file to $BACKUP_DIR.
make_backup() {
  # use sqlite3 to create backup (avoids corruption if db write in progress)
  SQL_NAME="db.sqlite3"
  SQL_BACKUP_DIR="/tmp"
  SQL_BACKUP_NAME=$SQL_BACKUP_DIR/$SQL_NAME
  if ! sqlite3 /data/$SQL_NAME ".backup '$SQL_BACKUP_NAME'"; then
    log_error "Failed to backup SQLite database"
    return 1
  fi

  # build a string of files and directories to back up
  cd /
  DATA="data"
  FILES=""
  FILES="$FILES $([ -d "$DATA/attachments" ] && echo $DATA/attachments)"
  FILES="$FILES $([ -d "$DATA/sends" ] && echo $DATA/sends)"
  FILES="$FILES $([ -r "$DATA/config.json" ] && echo $DATA/config.json)"
  FILES="$FILES $([ -r "$DATA/rsa_key.der" -o -r "$DATA/rsa_key.pem" -o -r "$DATA/rsa_key.pub.der" ] && echo $DATA/rsa_key*)"

  FILES="$FILES $([ -r .env ] && [ "$BACKUP_ENV" = "true" ] && echo .env)"

  # tar up files and encrypt with openssl and encryption key
  BACKUP_DIR=/$DATA/backups
  mkdir -p "$BACKUP_DIR"
  BACKUP_FILE=$BACKUP_DIR/"bw_backup_$(date "+%F-%H%M%S").tar.gz"

  # If a password is provided, run it through openssl
  if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
    BACKUP_FILE=$BACKUP_FILE.aes256
    if ! tar czf - -C / $FILES -C "$SQL_BACKUP_DIR" "$SQL_NAME" | openssl enc -e -aes256 -salt -pbkdf2 -pass pass:${BACKUP_ENCRYPTION_KEY} -out $BACKUP_FILE; then
      log_error "$(printf "Failed to create encrypted backup")"
      rm -f $SQL_BACKUP_NAME
      return 1
    fi
  else
    if ! tar czf "$BACKUP_FILE" -C / $FILES -C $SQL_BACKUP_DIR "$SQL_NAME"; then
      log_error "$(printf "Failed to create tar backup")"
      rm -f $SQL_BACKUP_NAME
      return 1
    fi
  fi
  printf "Backup file created at %b\n" "$BACKUP_FILE" >> $LOG

  # cleanup tmp folder
  rm -f $SQL_BACKUP_NAME

  # rm any backups older than 30 days
  find $BACKUP_DIR/* -mtime +$BACKUP_DAYS -exec rm {} \;

  printf "$BACKUP_FILE"
  return 0
}


##############################################################################################
# Main Backup 

# backup
# Args:
#   $1 - METHOD: Backup method name (local, email, rclone)
#   $2 - RESULT: Path to the backup file produced by make_backup()
# Behavior:
#   Performs method-specific actions (no-op for local, emails the file for email, rclones the file for rclone).
# Returns:
#   0 on success, non-zero on failure.
backup(){
  METHOD=$1
  RESULT=$2

  case $METHOD in
    local)
      printf "Running local backup\n" >> $LOG
      if [ "$BACKUP_EMAIL_NOTIFY" == "true" ] && [ "$BACKUP_EMAIL_NOTIFY_ON_FAILURE_ONLY" != "true" ]; then
        email_send "$SMTP_FROM_NAME - local backup completed" "Local backup completed"
      fi
      ;;

    email)
      # Handle E-mail Backup
      printf "Running email backup\n" >> $LOG
      # Backup and send e-mail
      if [ -n "$RESULT" ]; then
        FILENAME=$(basename $RESULT)
        BODY=$(email_body $FILENAME)
        email_send "$SMTP_FROM_NAME - $FILENAME" "$BODY" $RESULT
      else
        printf "Error: No result file to email.\n" >> $LOG
      fi
      ;;

    rclone)
      # Handle rclone Backup
      printf "Running rclone backup\n" >> $LOG
      # Initialize rclone if BACKUP=rclone and $(command -v rclone) is blank
      if [ "$METHOD" = "rclone" -a -z "$(command -v rclone)" ]; then
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
          # Send failure email
          if [ "$BACKUP_EMAIL_NOTIFY" == "true" ]; then
            email_send "$SMTP_FROM_NAME - rclone backup failed" "Rclone backup failed to ${SYNC_FAILED_CNT} of ${SYNC_TOTAL_CNT} remotes.\n\nErrors:\n$SYNC_ERROR_LOG"
          fi
        else
          # Success
          if [ "$BACKUP_EMAIL_NOTIFY" == "true" ] && [ "$BACKUP_EMAIL_NOTIFY_ON_FAILURE_ONLY" != "true" ]; then
            email_send "$SMTP_FROM_NAME - rclone backup completed" "Rclone backup completed successfully to ${SYNC_TOTAL_CNT} remotes."
          fi
        fi
      else
        printf "Rclone backup skipped - BACKUP_RCLONE_CONF not found or empty\n" >> $LOG
        if [ "$BACKUP_EMAIL_NOTIFY" == "true" ]; then
            email_send "$SMTP_FROM_NAME - rclone config error" "Rclone backup failed: Configuration file not found at $BACKUP_RCLONE_CONF."
        fi
      fi
      ;;

  esac
}

###### Restore ###############################################################################

# stop_bitwarden
# Args:
#   None
# Behavior:
#   Attempts to stop the `bitwarden` Docker container using `docker stop`.
# Returns:
#   0 on success; non-zero if container could not be stopped.
stop_bitwarden() {
  log "$(printf "Stopping vaultwarden container...")"
  if ! docker stop bitwarden > /dev/null; then
    log "$(printf "Could not stop bitwarden container. Restoration may fail if database is in use.")" "WARNING"
    return 1
  fi
  return 0
}

# start_bitwarden
# Args:
#   None
# Behavior:
#   Attempts to start the `bitwarden` Docker container using `docker start`.
# Returns:
#   0 on success; non-zero if the container failed to start.
start_bitwarden() {
  log "$(printf "Starting vaultwarden container...")"
  if ! docker start bitwarden > /dev/null; then
    log "$(printf "Could not start bitwarden container. You may need to start it manually")" "WARNING"
    return 1
  fi
  return 0
}

# restore_backup
# Args:
#   $1 - BACKUP_FILE: Path to the backup archive to restore (may be encrypted with .aes256)
# Behavior:
#   Creates an emergency backup of current data, decrypts (if necessary) and extracts the provided
#   backup into a temporary directory, stops the running container, restores DB and data files,
#   and restarts the container if it was stopped. Writes progress and errors to the log.
# Returns:
#   Exits with non-zero on fatal errors; returns 0 on successful completion.
restore_backup() {
  BACKUP_FILE=$1
  
  if [ ! -f "$BACKUP_FILE" ]; then
    log_error "$(printf "Error: Backup file %s not found" "$BACKUP_FILE")"
    exit 1
  fi
  
  # Create backup using existing local backup function
  log "Creating backup of current state before restoration..."

  log "$(printf "Attempting to restore from %s" "$BACKUP_FILE")"
  
  # Create a temporary directory for extraction
  RESTORE_TMP_DIR=$(mktemp -d)
  
  # Check if this is an encrypted backup
  if [ "${BACKUP_FILE%.aes256}" != "$BACKUP_FILE" ]; then
    log "Detected encrypted backup file."
    
    # Check for decryption key in environment variables first
    if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
      DECRYPT_KEY="$BACKUP_ENCRYPTION_KEY"
      log "Using encryption key from environment variable."
    else
      # No key in environment, try interactive prompt
      if [ -t 0 ]; then
        printf "Enter decryption key: "
        stty -echo
        read -r DECRYPT_KEY
        stty echo
        echo # Add newline after password input
        
        # Verify key was entered
        if [ -z "$DECRYPT_KEY" ]; then
          printf "Error: No decryption key provided.\n" >&2
          rm -rf "$RESTORE_TMP_DIR"
          exit 1
        fi
      else
        log_error "No decryption key available. Cannot prompt in non-interactive mode. Please provide the key via BACKUP_ENCRYPTION_KEY environment variable."
        rm -rf "$RESTORE_TMP_DIR"
        exit 1
      fi
    fi
    
    # Decrypt and extract
    log "$(printf "Decrypting backup file %s..." "$BACKUP_FILE")"
    if ! openssl enc -d -aes256 -salt -pbkdf2 -pass pass:"${DECRYPT_KEY}" -in "$BACKUP_FILE" | tar xzf - -C "$RESTORE_TMP_DIR"; then
      log_error "Failed to decrypt or extract the backup file. Exiting"
      rm -rf "$RESTORE_TMP_DIR"
      exit 1
    fi
  else
    # Extract unencrypted backup
    log "$(printf "Extracting backup file...")"
    if ! tar xzf "$BACKUP_FILE" -C "$RESTORE_TMP_DIR"; then
      log_error "Failed to extract the backup file. Exiting"
      rm -rf "$RESTORE_TMP_DIR"
      exit 1
    fi
  fi
  
  # Create backup using existing local backup function
  printf "Creating backup of current state before restoration...\n" >> $LOG
  if ! make_backup > /dev/null; then
    printf "Warning: Safety backup failed! Proceeding anyway...\n" >> $LOG
  fi
  
  # Stop the bitwarden container before restoration
  BITWARDEN_STOPPED=0
  if command -v docker >/dev/null 2>&1; then
    if stop_bitwarden; then
      BITWARDEN_STOPPED=1
    fi
  else
    log "Docker command not found. Cannot stop/start bitwarden container." "WARNING"
  fi
  
  # Create a timestamp for backup files
  TIMESTAMP=$(date "+%F-%H%M%S")
  
  # Restore the SQLite database
  if [ -f "$RESTORE_TMP_DIR/db.sqlite3" ]; then
    log "Restoring database..."
    if [ -f "/data/db.sqlite3" ]; then
      rm -f "/data/db.sqlite3"
    fi
    
    # Restore the database
    cp "$RESTORE_TMP_DIR/db.sqlite3" "/data/db.sqlite3"
    RET_CODE=$?
    if [ $RET_CODE -ne 0 ]; then
      log_error "Failed to restore database. Exiting"
      rm -rf "$RESTORE_TMP_DIR"
      exit 1
    else
      log "Database restored successfully."
      # Set correct permissions for db file
      chmod 644 "/data/db.sqlite3" || true
    fi
  else
    log_error "Could not find database in backup."
    rm -rf "$RESTORE_TMP_DIR"
    exit 1
  fi
  
  # Restore other files and directories

  log "Restoring data files..."
  RESTORE_FAILURE=$(printf "Because the database has been restored, you may need to manually restore the emergency backup at %s." "$EMERGENCY_BACKUP")

  # Restore attachments
  if [ -d "$RESTORE_TMP_DIR/data/attachments" ]; then
    if [ -d "/data/attachments" ]; then
      rm -rf "/data/attachments"
    fi
    cp -r "$RESTORE_TMP_DIR/data/attachments" "/data/" || log "$(printf "Failed to restore attachments. %s" "$RESTORE_FAILURE")" "WARNING"
  fi
  
  # Restore sends
  if [ -d "$RESTORE_TMP_DIR/data/sends" ]; then
    if [ -d "/data/sends" ]; then
      rm -rf "/data/sends"
    fi
    cp -r "$RESTORE_TMP_DIR/data/sends" "/data/" || log "$(printf "Failed to restore sends. %s" "$RESTORE_FAILURE")" "WARNING"
  fi
  
  # Restore config.json
  if [ -f "$RESTORE_TMP_DIR/data/config.json" ]; then
    if [ -f "/data/config.json" ]; then
      rm -f "/data/config.json"
    fi
    cp "$RESTORE_TMP_DIR/data/config.json" "/data/" || log "$(printf "Failed to restore config.json. %s" "$RESTORE_FAILURE")" "WARNING"
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
        cp "$key_file" "/data/" || log "$(printf "Failed to restore %s. %s" "$KEY_FILENAME" "$RESTORE_FAILURE")" "WARNING"
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
    
    log "$INSTRUCTIONS"
  fi
  
  # Clean up
  rm -rf "$RESTORE_TMP_DIR"
  
  # Restart bitwarden container if we stopped it
  if [ "$BITWARDEN_STOPPED" -eq 1 ] && command -v docker >/dev/null 2>&1; then
    start_bitwarden
  fi
  
  log "Restore completed"
}

###### Main Execution ########################################################################

COMMAND_ERROR=0
USAGE=$(printf "Usage: $0 {local,email,rclone|restore <backup_file>}\n")
VALID="local email rclone"

case "$1" in
  restore)
    if [ -z "$2" ]; then
      log_error "No backup file specified."
      printf '%b\n' "$USAGE" >&2
      exit 1
    fi
    restore_backup "$2"
    ;;
  *)
    # Check for extraneous arguments
    if [ -n "$2" ]; then
      log_error "Error: Unexpected argument '$2'. Only one backup method argument is allowed."
      printf '%b\n' "$USAGE" >&2
      exit 1
    fi
    
    # validate backup methods - fail fast
    METHODS=$(printf "%s" "$1" | tr ',' ' ')
    for METHOD in $METHODS; do
      if ! echo $VALID | grep -q -w "$METHOD"; then
        ERROR=$(printf "Invalid backup method '%s'; backup failed\n" "$METHOD")
        log_error "$ERROR"
        printf '%b\n' "$USAGE" >&2
        if [ "$BACKUP_EMAIL_NOTIFY" = "true" ]; then
          email_send "$SMTP_FROM_NAME - Backup Failed" "$ERROR"
        fi
        exit 1
      fi
    done

    # create backup file
    # capture result (filename) AND the exit code separately
    # send notification & exit if backup failed
    RESULT=$(make_backup)
    BACKUP_EXIT_CODE=$?
    if [ $BACKUP_EXIT_CODE -eq 0 ]; then
      log "$(printf "Created backup at: %s" "$RESULT")"
    else
      ERROR="Backup creation failed. Check the logs for additional details."
      log_error "$ERROR"
      if [ "$BACKUP_EMAIL_NOTIFY" = "true" ]; then
        email_send "$SMTP_FROM_NAME - Backup Failed" "$ERROR"
      fi
      exit 1
    fi
    
    SUCCESSFUL_BACKUPS=""
    for METHOD in $METHODS; do
      log "$(printf "Performing '%s' backup..." "$METHOD")"

      # We pass the exit code to backup function
      if ERROR=$(backup "$METHOD" "$RESULT"); then
        SUCCESSFUL_BACKUPS="$SUCCESSFUL_BACKUPS $METHOD"
        log "$(printf "Backup to %b completed" "$METHOD")"
      else
        ERROR="$(printf "Backup via %b failed: %b" "$METHOD" "$ERROR")"
        log_error "$ERROR"
        if [ "$BACKUP_EMAIL_NOTIFY" = "true" ]; then
          email_send "$SMTP_FROM_NAME - $METHOD Backup Failed" "$ERROR"
        fi
      fi
    done

    if [ -n "$SUCCESSFUL_BACKUPS" ]; then
      if [ "$BACKUP_EMAIL_NOTIFY" = "true" ] && [ "$BACKUP_EMAIL_NOTIFY_ON_FAILURE_ONLY" != "true" ]; then
        BODY="Backup completed successfully via: $SUCCESSFUL_BACKUPS"
        email_send "$SMTP_FROM_NAME - Backup Successful" "$BODY" "$RESULT"
      fi
    else
      log_error "All backup methods failed."
      exit 1
    fi
    ;;
esac