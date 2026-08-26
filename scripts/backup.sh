#!/usr/bin/env ash

# vaultwarden backup script for docker
# Copyright (C) 2021 Bradford Law
# Licensed under the terms of MIT

# set -u is on: an unset variable is an error rather than an empty string. In a
# script that builds rm and cp targets by interpolation, a typo silently
# expanding to nothing is the failure mode worth catching. Every optional
# setting is given an explicit default below, so absence stays a supported
# state -- a deployment that uses neither rclone nor e-mail is normal.
#
# set -e is deliberately NOT set. "cmd || fallback" and functions returning
# non-zero are used as ordinary control flow throughout, so enabling it would
# change the meaning of existing code rather than catch bugs in it. The
# destructive paths check their exit codes explicitly instead.
set -u

# Optional settings, defaulted so their absence is a documented state rather
# than an accident of shell behaviour, and so a typo in a name fails visibly.
: "${BACKUP_EMAIL_NOTIFY:=false}"
: "${BACKUP_EMAIL_NOTIFY_ON_FAILURE_ONLY:=false}"
: "${BACKUP_EMAIL_TO:=}"
: "${BACKUP_ENV:=false}"
: "${BACKUP_DAYS:=}"
: "${BACKUP_ENCRYPTION_KEY:=}"
: "${BACKUP_RCLONE_CONF:=}"
: "${BACKUP_RCLONE_DEST:=}"
: "${RESTORE_FORCE:=false}"
: "${BACKUP_MAX_AGE_DAYS:=8}"
: "${CHECK_STATE_FILE:=/data/backups/.last-status-alert}"
: "${METADATA_HOST:=metadata.google.internal}"

LOG=/var/log/backup.log
MUTTRC=/tmp/muttrc
DOCKER_API_VERSION=${DOCKER_API_VERSION:-1.43}
export DOCKER_API_VERSION

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
if [ "${1:-}" = "email" -o "$BACKUP_EMAIL_NOTIFY" = "true" ] && [ ! -f "$MUTTRC" ]; then
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
  log "Finished configuring email."
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
  # Names are second-resolution, so two backups in the same second would
  # collide. That is not hypothetical: restore_backup takes an emergency backup
  # into this same directory, and a collision there overwrites the very archive
  # being restored from -- the restore then silently reinstates the current
  # database instead of the backup, and the backup is gone. Never overwrite.
  BACKUP_BASE="bw_backup_$(date "+%F-%H%M%S")"
  _suffix=0
  while [ -e "$BACKUP_DIR/$BACKUP_BASE.tar.gz" ] || [ -e "$BACKUP_DIR/$BACKUP_BASE.tar.gz.aes256" ]; do
    _suffix=$((_suffix + 1))
    BACKUP_BASE="bw_backup_$(date "+%F-%H%M%S")-$_suffix"
  done
  BACKUP_FILE=$BACKUP_DIR/"$BACKUP_BASE.tar.gz"

  # If a password is provided, run it through openssl
  if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
    BACKUP_FILE=$BACKUP_FILE.aes256
    # -pass env: rather than pass:. Command-line arguments are readable from
    # /proc/<pid>/cmdline by anything else in the container, and an unquoted
    # expansion also breaks on a key containing spaces or shell metacharacters.
    if ! BW_KEY="$BACKUP_ENCRYPTION_KEY" tar czf - -C / $FILES -C "$SQL_BACKUP_DIR" "$SQL_NAME" \
        | BW_KEY="$BACKUP_ENCRYPTION_KEY" openssl enc -e -aes256 -salt -pbkdf2 -pass env:BW_KEY -out "$BACKUP_FILE"; then
      log_error "$(printf "Failed to create encrypted backup")"
      rm -f "$SQL_BACKUP_NAME"
      return 1
    fi
  else
    if ! tar czf "$BACKUP_FILE" -C / $FILES -C $SQL_BACKUP_DIR "$SQL_NAME"; then
      log_error "$(printf "Failed to create tar backup")"
      rm -f "$SQL_BACKUP_NAME"
      return 1
    fi
  fi

  # cleanup tmp folder
  rm -f "$SQL_BACKUP_NAME"

  # rm any backups older than BACKUP_DAYS (only if BACKUP_DAYS is a positive integer)
  case "$BACKUP_DAYS" in
    ''|*[!0-9]*)
      log "BACKUP_DAYS is not set or not a positive integer; skipping old-backup pruning" "WARNING"
      ;;
    *)
      # -name guards against deleting anything else the operator keeps here.
      find "$BACKUP_DIR" -type f -name 'bw_backup_*' -mtime +"$BACKUP_DAYS" -exec rm -f {} \;
      ;;
  esac

  # Returned via a named variable rather than stdout. log() writes INFO
  # messages to stdout, and callers use RESULT=$(make_backup), so a single
  # informational line added inside this function would be captured as part of
  # the path and passed to rm and cp. It works today only by accident.
  MAKE_BACKUP_RESULT=$BACKUP_FILE
  printf '%s' "$BACKUP_FILE"
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
      # Nothing additional to do for local backup
      ;;

    email)
      if [ -n "$RESULT" ]; then
        FILENAME=$(basename $RESULT)
        BODY=$(email_body $FILENAME)
        email_send "$SMTP_FROM_NAME - $FILENAME" "$BODY" $RESULT
      else
        printf "No result file to email"
        return 1
      fi
      ;;

    rclone)
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
          printf "Failed to sync on ${SYNC_FAILED_CNT} of ${SYNC_TOTAL_CNT} remotes:\n  %b" "$SYNC_ERROR_LOG"
          return 1
        fi
      else
        printf "Configuration file not found at $BACKUP_RCLONE_CONF"
        return 1
      fi
      ;;
  esac

  return 0
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
  
  # Decide whether this restore can proceed BEFORE doing any work.
  #
  # The emergency backup below opens the live database with sqlite3, which
  # checkpoints and removes its -wal and -shm sidecars, and writes a new
  # archive. Neither is destructive, but both mean a late abort is not the
  # no-op the error message claims. Establishing the precondition first makes
  # "nothing has been changed" literally true.
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    if [ "$RESTORE_FORCE" != "true" ]; then
      log_error "This container cannot reach the Docker daemon, so it cannot confirm the vaultwarden container is stopped."
      log_error "Restore overwrites /data/db.sqlite3 in place. Doing that while vaultwarden holds it open risks losing writes or corrupting the vault."
      log_error "Nothing has been changed."
      log_error ""
      log_error "Stop the vault yourself and retry:"
      log_error "    docker-compose stop bitwarden"
      log_error "    docker exec -it backup backup restore $BACKUP_FILE"
      log_error "    docker-compose start bitwarden"
      log_error ""
      log_error "If it is already stopped, set RESTORE_FORCE=true to proceed."
      exit 1
    fi
    log "RESTORE_FORCE=true and the Docker daemon is unreachable: proceeding on the operator's assurance that the vault is stopped." "WARNING"
  fi

  # Create backup using existing local backup function
  log "Creating backup of current state before restoration..."

  EMERGENCY_BACKUP=$(make_backup)
  BACKUP_EXIT_CODE=$?

  if [ $BACKUP_EXIT_CODE -ne 0 ]; then
    log_error "Safety backup failed! Exiting."
    exit $BACKUP_EXIT_CODE
  fi

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
    if ! BW_KEY="$DECRYPT_KEY" openssl enc -d -aes256 -salt -pbkdf2 -pass env:BW_KEY -in "$BACKUP_FILE" | tar xzf - -C "$RESTORE_TMP_DIR"; then
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
  
  
  # Stop the bitwarden container before restoration.
  #
  # This must abort rather than warn. Restore overwrites /data/db.sqlite3 in
  # place; doing that while vaultwarden holds the database open risks losing
  # writes or corrupting it. Earlier versions logged a warning here and carried
  # on, which meant removing the Docker socket from the container silently
  # turned an interlock into a message nobody reads.
  #
  # RESTORE_FORCE=true overrides, for the case where the operator has already
  # stopped the container by other means -- docker-compose stop on the host,
  # for instance, which this container cannot observe without the socket.
  BITWARDEN_STOPPED=0
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if stop_bitwarden; then
      BITWARDEN_STOPPED=1
    elif [ "$RESTORE_FORCE" != "true" ]; then
      # The daemon is reachable and still refused. That is a real failure, not
      # a missing socket, so abort rather than overwrite a possibly live vault.
      log_error "The Docker daemon is reachable but the vaultwarden container could not be stopped."
      log_error "Abandoning the restore rather than overwriting a database that may still be open."
      log_error "The emergency backup taken a moment ago is at: $EMERGENCY_BACKUP"
      rm -rf "$RESTORE_TMP_DIR"
      exit 1
    else
      log "RESTORE_FORCE=true: proceeding although the container could not be stopped." "WARNING"
    fi
  fi
  
  # Create a timestamp for backup files
  TIMESTAMP=$(date "+%F-%H%M%S")
  
  # Restore the SQLite database
  if [ -f "$RESTORE_TMP_DIR/db.sqlite3" ]; then
    log "Restoring database..."
    if [ -f "/data/db.sqlite3" ]; then
      rm -f "/data/db.sqlite3"
    fi

    # Remove the write-ahead log and shared-memory sidecars belonging to the
    # database being replaced. Leaving them beside a restored file pairs a new
    # database with another database's journal: SQLite may refuse to open it,
    # or replay stale frames over the data just restored. The backup does not
    # contain them and does not need to -- sqlite3 .backup produces a single
    # consistent file.
    for sidecar in /data/db.sqlite3-wal /data/db.sqlite3-shm /data/db.sqlite3-journal; do
      if [ -e "$sidecar" ]; then
        rm -f "$sidecar" && log "$(printf "Removed stale %s from the previous database" "$sidecar")"
      fi
    done
    
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
    FILENAME=".env.restored"
    REF_LOCATION=$(printf "/data/%b" "$FILENAME")
    cp "$RESTORE_TMP_DIR/.env" "$REF_LOCATION" || log "$(printf "Failed to copy .env to %s" "$REF_LOCATION")" "WARNING"
    
    # Print detailed instructions for the user
    INSTRUCTIONS="
    ---------------------------------------------------------------------------------
    IMPORTANT: .ENV FILE NOTICE
    ---------------------------------------------------------------------------------
    
    The .env file cannot be automatically restored while Docker Compose is running.
    A copy of the restored .env file has been placed at:
      bitwarden/$FILENAME
    
    To complete the restoration process manually:
    
    1. Review the differences between your current .env and the restored version:
       diff .env bitwarden/$FILENAME
    
    2. To fully apply the restored .env:
       a. Stop all services: docker-compose down
       b. Replace your .env file: cp bitwarden/$FILENAME .env
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

###### Status Checks #########################################################################

# metadata
# Args:
#   $1 - path under computeMetadata/v1/
# Behavior:
#   Queries the GCE metadata server. Returns empty on any failure, including
#   when running somewhere that is not GCE.
metadata() {
  # METADATA_HOST is overridable so tests can simulate running outside GCE.
  curl -s -m 5 -H "Metadata-Flavor: Google" \
    "http://${METADATA_HOST:-metadata.google.internal}/computeMetadata/v1/$1" 2>/dev/null
}

# cos_family_status
# Args:
#   $1 - milestone number
# Behavior:
#   Reports whether cos-<milestone>-lts still resolves. Google removes the
#   family pointer at end of support, so a 404 is the end-of-life signal.
#   Individual images are marked deprecated as newer builds supersede them
#   inside a healthy family, which is why this asks about the family and not
#   about an image.
# Returns:
#   Prints the HTTP status code.
cos_family_status() {
  _tok=$(metadata "instance/service-accounts/default/token" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
  [ -n "$_tok" ] || { printf '000'; return 1; }
  curl -s -m 8 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $_tok" \
    "https://compute.googleapis.com/compute/v1/projects/cos-cloud/global/images/family/cos-$1-lts" 2>/dev/null
}

# check_status
# Behavior:
#   Two checks that share one report: whether the host OS milestone is still
#   supported, and whether a recent backup exists. Both are failures that are
#   invisible by default -- an unsupported milestone stops receiving patches
#   silently, and cron discards the output of a backup that never runs.
#   Sends at most one e-mail per distinct problem, tracked in CHECK_STATE_FILE.
# Returns:
#   0 when everything is healthy, 1 when something needs attention.
check_status() {
  PROBLEMS=""
  REPORT=""

  # --- host OS milestone ---
  IMAGE=$(metadata "instance/image")
  MILESTONE=$(printf '%s' "$IMAGE" | sed -n 's/.*cos-\(stable-\)\?\([0-9][0-9]*\)-.*/\2/p')

  if [ -z "$MILESTONE" ]; then
    log "Not running on a GCE Container-Optimized OS instance, or metadata is unavailable; skipping the OS check."
  else
    CODE=$(cos_family_status "$MILESTONE")
    case "$CODE" in
      404)
        PROBLEMS="$PROBLEMS os-eol"
        REPORT="$REPORT$(printf 'Container-Optimized OS milestone %s is no longer supported.\n\nThe image family cos-%s-lts has been withdrawn, so this host receives no\nfurther security patches for the OS, the kernel, containerd or Docker, and\nthe in-milestone update timer will correctly find nothing forever.\n\nUpgrading means building a new instance:\n\n    ./utilities/upgrade-cos.sh --instance <name> --zone <zone>\n' "$MILESTONE" "$MILESTONE")

"
        ;;
      200)
        log "$(printf "Host OS milestone %s is still supported." "$MILESTONE")"
        ;;
      *)
        log "$(printf "Could not determine support status for milestone %s (HTTP %s); skipping." "$MILESTONE" "$CODE")" "WARNING"
        ;;
    esac

    # Look for newer LTS milestones. Steps of 4 match Google's numbering.
    NEWER=""
    _m=$((MILESTONE + 4))
    _tries=0
    while [ $_tries -lt 8 ]; do
      [ "$(cos_family_status "$_m")" = "200" ] && NEWER="$_m"
      _m=$((_m + 4))
      _tries=$((_tries + 1))
    done
    if [ -n "$NEWER" ] && [ "$NEWER" != "$MILESTONE" ]; then
      REPORT="$REPORT$(printf 'A newer LTS milestone is available: cos-%s-lts (currently on %s).\n' "$NEWER" "$MILESTONE")

"
      case "$PROBLEMS" in *os-eol*) ;; *) PROBLEMS="$PROBLEMS os-newer-$NEWER" ;; esac
    fi
  fi

  # --- backup freshness ---
  NEWEST=$(ls -t /data/backups/bw_backup_* 2>/dev/null | head -1)
  if [ -z "$NEWEST" ]; then
    PROBLEMS="$PROBLEMS no-backups"
    REPORT="$REPORT$(printf 'There are no backups at all in /data/backups.\n\n')"
  elif [ -n "$(find "$NEWEST" -mtime +"$BACKUP_MAX_AGE_DAYS" 2>/dev/null)" ]; then
    PROBLEMS="$PROBLEMS stale-backup"
    REPORT="$REPORT$(printf 'The newest backup is older than %s days.\n\n  %s\n\nScheduled backups appear to have stopped. cron discards script output, so\nthis fails silently: check "docker logs backup" and run a backup by hand:\n\n    docker exec backup ash /backup.sh %s\n\n' "$BACKUP_MAX_AGE_DAYS" "$NEWEST" "${BACKUP:-local}")"
  else
    log "$(printf "Newest backup is within %s days: %s" "$BACKUP_MAX_AGE_DAYS" "$(basename "$NEWEST")")"
  fi

  # --- report ---
  if [ -z "$PROBLEMS" ]; then
    log "Status check passed: OS milestone supported, backups current."
    rm -f "$CHECK_STATE_FILE"
    return 0
  fi

  printf '%s\n' "$REPORT" >&2

  # Alert once per distinct set of problems, so a persistent condition does not
  # mail every week until it is fixed.
  LAST=$(cat "$CHECK_STATE_FILE" 2>/dev/null || true)
  if [ "$LAST" = "$PROBLEMS" ]; then
    log "Same problems as the last check; not sending another e-mail."
  elif [ "$BACKUP_EMAIL_NOTIFY" = "true" ]; then
    email_send "${SMTP_FROM_NAME:-Bitwarden} - action needed" "$REPORT"
    printf '%s' "$PROBLEMS" > "$CHECK_STATE_FILE" 2>/dev/null || true
    log "Alert sent."
  else
    log "BACKUP_EMAIL_NOTIFY is not true, so no e-mail was sent." "WARNING"
  fi
  return 1
}

USAGE=$(printf "Usage: $0 {local,email,rclone|restore <backup_file>|check}\n")
VALID="local email rclone"

# ${1:-} throughout: with set -u a bare $1 is fatal when the script is
# invoked with no arguments, which is exactly when it should print usage.
case "${1:-}" in
  check)
    check_status
    exit $?
    ;;
  restore)
    if [ -z "${2:-}" ]; then
      log_error "No backup file specified."
      printf '%b\n' "$USAGE" >&2
      exit 1
    fi
    restore_backup "${2:-}"
    ;;
  *)
    # Check for extraneous arguments
    if [ -n "${2:-}" ]; then
      log_error "Error: Unexpected argument '${2:-}'. Only one backup method argument is allowed."
      printf '%b\n' "$USAGE" >&2
      exit 1
    fi
    
    # validate backup methods - fail fast
    METHODS=$(printf "%s" "${1:-}" | tr ',' ' ')
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