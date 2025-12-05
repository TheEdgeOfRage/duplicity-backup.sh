#!/usr/bin/env bash
#
# Copyright (c) 2008-2010 Damon Timm.
# Copyright (c) 2010 Mario Santagiuliana.
# Copyright (c) 2012-2018 Marc Gallet.
# Copyright (c) 2021 TheEdgeOfRage
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details.
#
# You should have received a copy of the GNU General Public License along with
# this program.  If not, see <http://www.gnu.org/licenses/>.
#
# ---------------------------------------------------------------------------- #

DBSH_VERSION="v1.7.1"

# make a backup of stdout and stderr for later
exec 6>&1
exec 7>&2

# ------------------------------------------------------------

usage(){
echo "USAGE:
  $(basename "$0") [options]

  Options:
    -c, --config CONFIG_FILE   specify the config file to use

    -b, --backup               runs an incremental backup
    -f, --full                 forces a full backup
    -v, --verify               verifies the backup
    -e, --cleanup              cleanup the backup (eg. broken sessions), by default using
                               duplicity --force flag, use --dry-run to actually log what
                               will be cleaned up without removing (see man duplicity
                               > ACTIONS > cleanup for details)
    -l, --list-current-files   lists the files currently backed up in the archive
    -s, --collection-status    show all the backup sets in the archive

        --restore [PATH]       restores the entire backup to [path]
        --restore-file [FILE_TO_RESTORE] [DESTINATION]
                               restore a specific file
        --restore-dir [DIR_TO_RESTORE] [DESTINATION]
                               restore a specific directory

    -t, --time TIME            specify the time from which to restore or list files
                               (see duplicity man page for the format)

    --backup-script            automatically backup the script and secret key(s) to
                               the current working directory

    -q, --quiet                silence most of output messages, except errors and output
                               that are intended for interactive usage. Silenced output
                               is still logged in the logfile.

    -n, --dry-run              perform a trial run with no changes made
    -d, --debug                echo duplicity commands to logfile
    -V, --version              print version information about this script and duplicity
    -h, --help                 print this help and exit

  CURRENT SCRIPT VARIABLES:
  ========================
    DEST (backup destination)       = ${DEST}
    INCLIST (directories included)  = ${INCLIST[*]:0}
    EXCLIST (directories excluded)  = ${EXCLIST[*]:0}
    ROOT (root directory of backup) = ${ROOT}
    LOGFILE (log file path)         = ${LOGFILE}
" >&6
USAGE=1
}

DUPLICITY="$(command -v duplicity)"

if [ ! -x "${DUPLICITY}" ]; then
  echo "ERROR: duplicity not installed, that's gotta happen first!" >&2
  exit 1
fi

DUPLICITY_VERSION=$(${DUPLICITY} --version)
DUPLICITY_VERSION=${DUPLICITY_VERSION//[^0-9\.]/}

version(){
  echo "duplicity-backup.sh ${DBSH_VERSION}"
  echo "duplicity ${DUPLICITY_VERSION}"
  exit 0
}

# Some expensive argument parsing that allows the script to
# be insensitive to the order of appearance of the options
# and to handle correctly option parameters that are optional
while getopts ":c:t:bfvelsqndhV-:" opt; do
  case $opt in
    # parse long options (a bit tricky because builtin getopts does not
    # manage long options and I don't want to impose GNU getopt dependancy)
    -)
      case "${OPTARG}" in
        # --restore [restore dest]
        restore)
          COMMAND=${OPTARG}
          # We try to find the optional value [restore dest]
          if [ -n "${!OPTIND:0:1}" ] && [ ! "${!OPTIND:0:1}" = "-" ]; then
            RESTORE_DEST=${!OPTIND}
            OPTIND=$(( OPTIND + 1 )) # we found it, move forward in arg parsing
          fi
        ;;
        # --restore-file [file to restore] [restore dest]
        # --restore-dir [path to restore] [restore dest]
        restore-file|restore-dir)
          COMMAND=${OPTARG}
          # We try to find the first optional value [file to restore]
          if [ -n "${!OPTIND:0:1}" ] && [ ! "${!OPTIND:0:1}" = "-" ]; then
            FILE_TO_RESTORE=${!OPTIND}
            OPTIND=$(( OPTIND + 1 )) # we found it, move forward in arg parsing
          else
            continue # no value for the restore-file option, skip the rest
          fi
          # We try to find the second optional value [restore dest]
          if [ -n "${!OPTIND:0:1}" ] && [ ! "${!OPTIND:0:1}" = "-" ]; then
            RESTORE_DEST=${!OPTIND}
            OPTIND=$(( OPTIND + 1 )) # we found it, move forward in arg parsing
          fi
        ;;
        config) # set the config file from the command line
          # We try to find the config file
          if [ -n "${!OPTIND:0:1}" ] && [ ! "${!OPTIND:0:1}" = "-" ]; then
            CONFIG=${!OPTIND}
            OPTIND=$(( OPTIND + 1 )) # we found it, move forward in arg parsing
          fi
        ;;
        time) # set the restore time from the command line
          # We try to find the restore time
          if [ -n "${!OPTIND:0:1}" ] && [ ! "${!OPTIND:0:1}" = "-" ]; then
            TIME=${!OPTIND}
            OPTIND=$(( OPTIND + 1 )) # we found it, move forward in arg parsing
          fi
        ;;
        quiet)
          QUIET=1
        ;;
        dry-run)
          DRY_RUN="--dry-run"
        ;;
        debug)
          ECHO=$(command -v echo)
        ;;
        help)
          usage
          exit 0
        ;;
        version)
          version
        ;;
        *)
          COMMAND=${OPTARG}
        ;;
        esac
    ;;
    # here are parsed the short options
    c) CONFIG=${OPTARG};; # set the config file from the command line
    t) TIME=${OPTARG};; # set the restore time from the command line
    b) COMMAND="backup";;
    f) COMMAND="full";;
    v) COMMAND="verify";;
    e) COMMAND="cleanup";;
    l) COMMAND="list-current-files";;
    s) COMMAND="collection-status";;
    q) QUIET=1;;
    n) DRY_RUN="--dry-run";; # dry run
    d) ECHO=$(command -v echo);; # debug
    h)
      usage
      exit 0
    ;;
    V) version;;
    :)
      echo "Option -${OPTARG} requires an argument." >&2
      COMMAND=""
    ;;
    \?)
      echo "Invalid option: -${OPTARG}" >&2
      COMMAND=""
    ;;
  esac
done
#echo "Options parsed. COMMAND=${COMMAND}" # for debugging


# ----------------  Read config file if specified -----------------

if [ -z "${CONFIG}" ];
then
  echo "ERROR: set config file destination with CONFIG env var or -c file flag" >&2
  usage
  exit 1
fi

if [ -n "${CONFIG}" ] && [ -f "${CONFIG}" ];
then
  # shellcheck disable=SC1090
  . "${CONFIG}"
else
  echo "ERROR: can't find config file! (${CONFIG})" >&2
  usage
  exit 1
fi

# ----------------------- Setup logging ---------------------------

# Setup logging as soon as possible, in order to be able to perform i/o redirection

LOGDIR=${LOGDIR:-"${HOME}/.local/log/duplicity/"}
LOG_FILE=${LOGDIR:-"duplicity-$(date +%Y-%m-%dT%H:%M:%S).log"}

# Ensure a trailing slash always exists in the log directory name
LOGDIR="${LOGDIR%/}/"
LOGFILE="${LOGDIR}${LOG_FILE}"

if [ ! -d "${LOGDIR}" ]; then
  echo "Attempting to create log directory ${LOGDIR} ..."
  if ! mkdir -p "${LOGDIR}"; then
    echo "Log directory ${LOGDIR} could not be created by this user: ${USER}" >&2
    echo "Aborting..." >&2
    exit 1
  else
    echo "Directory ${LOGDIR} successfully created."
  fi
elif [ ! -w "${LOGDIR}" ]; then
  echo "Log directory ${LOGDIR} is not writeable by this user: ${USER}" >&2
  echo "Aborting..." >&2
  exit 1
fi

# -------------------- Setup I/O redirections --------------------
# Magic from
# http://superuser.com/questions/86915/force-bash-script-to-use-tee-without-piping-from-the-command-line
#
#  ##### Redirection matrix in the case when quiet mode is ON #####
#
#  QUIET mode ON  | shown on screen | not shown on screen
#  ---------------+-----------------+----------------------
#  logged         |    fd2, fd3     |      fd1, fd5
#  not logged     |      fd4        |         -
#
#  ##### Redirection matrix in the case when quiet mode is OFF #####
#
#  QUIET mode OFF | shown on screen | not shown on screen
#  ---------------+-----------------+----------------------
#  logged         | fd1, fd2, fd3   |        fd5
#  not logged     |      fd4        |         -
#
# fd1 is stdout and is always logged but only shown if not QUIET
# fd2 is stderr and is always shown on screen and logged
# fd3 is like stdout but always shown on screen (for interactive prompts)
# fd4 is always shown on screen but never logged (for the usage text)
# fd5 is never shown on screen but always logged (for delimiters in the log)
#

# fd2 and fd3 are always logged and shown on screen via tee
# for fd2 (original stderr) the output of tee needs to be redirected to stderr
exec 2> >(tee -ia "${LOGFILE}" >&2)
# create fd3 as a redirection to stdout and the logfile via tee
exec 3> >(tee -ia "${LOGFILE}")

# create fd4 as a copy of stdout, but that won't be redirected to tee
# so that it is always shown and never logged
exec 4>&1

# create fd5 as a direct redirection to the logfile
# so that the content is never shown on screen but always logged
exec 5>> "${LOGFILE}"

# finally we modify stdout (fd1) to always being logged (like fd3 and fd5)
# but only being shown on screen if quiet mode is not active
if [[ ${QUIET} == 1 ]]; then
  # Quiet mode: stdout not shown on screen but still logged via fd5
  exec 1>&5
else
  # Normal mode: stdout shown on screen and logged via fd3
  exec 1>&3
fi

# tests for debugging the magic
#echo "redirected to fd1"
#echo "redirected to fd2" >&2
#echo "redirected to fd3" >&3
#echo "redirected to fd4" >&4
#echo "redirected to fd5" >&5

# ------------------------- Setting up variables ------------------------

if [ -n "${DRY_RUN}" ]; then
  STATIC_OPTIONS="${DRY_RUN} ${STATIC_OPTIONS}"
fi

if [ -n "${STORAGECLASS}" ]; then
  STATIC_OPTIONS="${STATIC_OPTIONS} ${STORAGECLASS}"
fi

SIGN_PASSPHRASE=${PASSPHRASE}

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_PROFILE
export PASSPHRASE
export SIGN_PASSPHRASE

if [[ -n "${BACKEND_PASSWORD}" ]]; then
  export BACKEND_PASSWORD
fi

if [[ -n "${TMPDIR}" ]]; then
  export TMPDIR
fi

# File to use as a lock. The lock is used to insure that only one instance of
# the script is running at a time.
LOCKFILE=${LOGDIR}backup.lock

ENCRYPT="--gpg-options \"${GPG_OPTIONS}\""
if [ -n "${GPG_ENC_KEY}" ] && [ -n "${GPG_SIGN_KEY}" ]; then
  if [ "${HIDE_KEY_ID}" = "yes" ]; then
    ENCRYPT="${ENCRYPT} --hidden-encrypt-key=${GPG_ENC_KEY}"
    if [ "${COMMAND}" != "restore" ] && [ "${COMMAND}" != "restore-file" ] && [ "${COMMAND}" != "restore-dir" ]; then
      ENCRYPT="${ENCRYPT} --sign-key=${GPG_SIGN_KEY}"
    fi
  else
    ENCRYPT="${ENCRYPT} --encrypt-key=${GPG_ENC_KEY} --sign-key=${GPG_SIGN_KEY}"
  fi
elif [ -n "${PASSPHRASE}" ]; then
  ENCRYPT=""
fi

NO_S3CMD="WARNING: s3cmd not found in PATH, remote file \
size information unavailable."
NO_S3CMD_CFG="WARNING: s3cmd is not configured, run 's3cmd --configure' \
in order to retrieve remote file size information. Remote file \
size information unavailable."

NO_B2CMD="WARNING: b2 not found in PATH, remote file size information \
unavailable. Is the python-b2 package installed?"

if  [ "$(echo "${DEST}" | cut -c 1,2)" = "s3" ] || [ "$(echo "${DEST}" | cut -c 1,2)" = "bo" ]; then
  DEST_IS_S3=true
  S3CMD="$(command -v s3cmd)"
  if [ ! -x "${S3CMD}" ]; then
    echo "${NO_S3CMD}"; S3CMD_AVAIL=false
  elif [ -z "${S3CMD_CONF_FILE}" ] && [ ! -f "${HOME}/.s3cfg" ]; then
    S3CMD_CONF_FOUND=false
    echo "${NO_S3CMD_CFG}"; S3CMD_AVAIL=false
  elif [ -n "${S3CMD_CONF_FILE}" ] && [ ! -f "${S3CMD_CONF_FILE}" ]; then
    S3CMD_CONF_FOUND=false
    echo "${S3CMD_CONF_FILE} not found, check S3CMD_CONF_FILE variable in duplicity-backup's configuration!";
    echo "${NO_S3CMD_CFG}";
    S3CMD_AVAIL=false
  else
    # shellcheck disable=SC2034
    S3CMD_AVAIL=true
    # shellcheck disable=SC2034
    S3CMD_CONF_FOUND=true
    if [ -n "${S3CMD_CONF_FILE}" ] && [ -f "${S3CMD_CONF_FILE}" ]; then
      # if conf file specified and it exists then add it to the command line for s3cmd
      S3CMD="${S3CMD} -c ${S3CMD_CONF_FILE}"
    fi
  fi
else
  DEST_IS_S3=false
fi

if  [ "$(echo "${DEST}" | cut -c 1,2)" = "b2" ]; then
  DEST_IS_B2=true
  B2CMD="$(command -v b2)"
  if [ ! -x "${B2CMD}" ]; then
    echo "${NO_B2CMD}"
    # shellcheck disable=SC2034
    B2CMD_AVAIL=false
  fi
else
  # shellcheck disable=SC2034
  DEST_IS_B2=false
fi

config_sanity_fail()
{
  EXPLANATION=$1
  CONFIG_VAR_MSG="Oops!! ${0} was unable to run!\nWe are missing one or more important variables in the configuration file.\nCheck your configuration because it appears that something has not been set yet."
  echo -e "${CONFIG_VAR_MSG}\n  ${EXPLANATION}." >&2
  echo -e "---------------------    END    ---------------------\n" >&5
  exit 1
}

check_variables ()
{
  [[ ${ROOT} = "" ]] && config_sanity_fail "ROOT must be configured"
  [[ ${DEST} = "" || ${DEST} = "s3+http://backup-foobar-bucket/backup-folder/" ]] && config_sanity_fail "DEST must be configured"
  [[ ${INCLIST[0]} = "/home/foobar_user_name/Documents/" ]] && config_sanity_fail "INCLIST must be configured"
  [[ ${EXCLIST[0]} = "/home/foobar_user_name/Documents/foobar-to-exclude" ]] && config_sanity_fail "EXCLIST must be configured"
  [[ ( ${ENCRYPTION} = "yes" && (${GPG_ENC_KEY} = "foobar_gpg_key" || \
       ${GPG_SIGN_KEY} = "foobar_gpg_key" || \
       ${PASSPHRASE} = "foobar_gpg_passphrase")) ]] && \
  config_sanity_fail "ENCRYPTION is set to 'yes', but GPG_ENC_KEY, GPG_SIGN_KEY, or PASSPHRASE have not been configured"
  [[ ( ${DEST_IS_S3} = true && (${AWS_ACCESS_KEY_ID} = "foobar_aws_key_id" || ${AWS_SECRET_ACCESS_KEY} = "foobar_aws_access_key" )) ]] && \
  config_sanity_fail "An s3 DEST has been specified, but AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY have not been configured"
  [[ -n "${INCEXCFILE}" && ! -f ${INCEXCFILE} ]] && config_sanity_fail "The specified INCEXCFILE ${INCEXCFILE} does not exists"
}

mailcmd_sendmail() {
  # based on http://linux.die.net/man/8/sendmail.sendmail
  echo -e "From: ${EMAIL_FROM}\nSubject: ${EMAIL_SUBJECT}\n" | cat - "${LOGFILE}" | ${MAILCMD} "${EMAIL_TO}"
}
mailcmd_ssmtp() {
  # based on http://linux.die.net/man/8/ssmtp
  echo -e "From: ${EMAIL_FROM}\nSubject: ${EMAIL_SUBJECT}\n" | cat - "${LOGFILE}" | ${MAILCMD} "${EMAIL_TO}"
}
mailcmd_msmtp() {
  # based on http://manpages.ubuntu.com/manpages/precise/en/man1/msmtp.1.html
  echo -e "Subject: ${EMAIL_SUBJECT}\n" | cat - "${LOGFILE}" | ${MAILCMD} -f "${EMAIL_FROM}" -- "${EMAIL_TO}"
}
mailcmd_bsd_mailx() {
  # based on http://man.he.net/man1/bsd-mailx
  ${MAILCMD} -s "${EMAIL_SUBJECT}" -a "From: ${EMAIL_FROM}" "${EMAIL_TO}" < "${LOGFILE}"
}
mailcmd_heirloom_mailx() {
  # based on http://heirloom.sourceforge.net/mailx/mailx.1.html
  ${MAILCMD} -s "${EMAIL_SUBJECT}" -S from="${EMAIL_FROM}" "${EMAIL_TO}" < "${LOGFILE}"
}
mailcmd_nail() {
  # based on http://linux.die.net/man/1/nail
  ${MAILCMD} -s "${EMAIL_SUBJECT}" -r "${EMAIL_FROM}" "${EMAIL_TO}" < "${LOGFILE}"
}
mailcmd_else() {
  ${MAILCMD} "${EMAIL_SUBJECT}" "${EMAIL_FROM}" "${EMAIL_TO}" < "${LOGFILE}"
}

email_logfile()
{
  if [ -n "${EMAIL_TO}" ]; then

      MAILCMD=$(command -v "${MAIL}")
      MAILCMD_REALPATH=$(readlink -e "${MAILCMD}")
      MAILCMD_BASENAME=${MAILCMD_REALPATH##*/}

      if [ ! -x "${MAILCMD}" ]; then
          echo -e "Email couldn't be sent. ${MAIL} not available." >&2
      else
          EMAIL_SUBJECT=${EMAIL_SUBJECT:="duplicity-backup ${BACKUP_STATUS:-"ERROR"} (${HOSTNAME}) ${LOG_FILE}"}
          case ${MAIL} in
            ssmtp)
              mailcmd_ssmtp;;
            msmtp)
              mailcmd_msmtp;;
            mail|mailx)
              case ${MAILCMD_BASENAME} in
                bsd-mailx|mail.mailutils)
                  mailcmd_bsd_mailx;;
                heirloom-mailx)
                  mailcmd_heirloom_mailx;;
                s-nail)
                  mailcmd_nail;;
                *)
                  mailcmd_else;;
              esac
              ;;
            sendmail)
              mailcmd_sendmail;;
            nail)
              mailcmd_nail;;
            *)
              mailcmd_else;;
          esac

          echo -e "Email notification sent to ${EMAIL_TO} using ${MAIL}"
      fi
  fi
}

send_notification()
{
  if [ -n "${NOTIFICATION_SERVICE}" ]; then
    echo "-----------[ Notification Request ]-----------"
    NOTIFICATION_CONTENT="duplicity-backup ${BACKUP_STATUS:-"ERROR"} [${HOSTNAME}] - \`${LOGFILE}\`"

    if [ "${NOTIFICATION_SERVICE}" = "telegram" ]; then
      curl -s --max-time 10 -d "chat_id=${TELEGRAM_CHATID}&disable_web_page_preview=1&text=${NOTIFICATION_CONTENT}" "https://api.telegram.org/bot${TELEGRAM_KEY}/sendMessage" >/dev/null
      echo -e "Telegram notification sent"
    else
      echo -e "Unsupported notification service: ${NOTIFICATION_SERVICE}" >&2
    fi

    echo -e "\n----------------------------------------------\n"
  fi
}

get_lock()
{
  echo "Attempting to acquire lock ${LOCKFILE}" >&5
  if ( set -o noclobber; echo "$$" > "${LOCKFILE}" ) 2> /dev/null; then
      # The lock succeeded. Create a signal handler to remove the lock file when the process terminates.
      trap 'EXITCODE=$?; echo "Removing lock. Exit code: ${EXITCODE}" >> ${LOGFILE}; rm -f "${LOCKFILE}"' EXIT
      echo "successfully acquired lock." >&5
  else
      # Write lock acquisition errors to log file and stderr
      echo "lock failed, could not acquire ${LOCKFILE}" >&2
      echo "lock held by $(cat "${LOCKFILE}")" >&2
      email_logfile
      send_notification
      exit 2
  fi
}

include_exclude()
{
  # Changes to handle spaces in directory names and filenames
  # and wrapping the files to include and exclude in quotes.
  OLDIFS=$IFS
  IFS=$(echo -en "\t\n")

  # Exclude device files?
  if [ -n "${EXDEVICEFILES}" ] && [ "${EXDEVICEFILES}" -ne 0 ]; then
    TMP=" --exclude-device-files"
    EXCLUDE=${EXCLUDE}${TMP}
  fi

  for include in "${INCLIST[@]}"
  do
    if [[ -n "$include" ]]; then
      TMP=" --include='$include'"
      INCLUDE=${INCLUDE}${TMP}
    fi
  done

  for exclude in "${EXCLIST[@]}"
  do
    if [[ -n "$exclude" ]]; then
      TMP=" --exclude '$exclude'"
      EXCLUDE=${EXCLUDE}${TMP}
    fi
  done

  # Include/Exclude globbing filelist
  if [ "${INCEXCFILE}" != '' ]; then
    TMP=" --include-filelist '${INCEXCFILE}'"
    INCLUDE=${INCLUDE}${TMP}
  fi

  # INCLIST and globbing filelist is empty so every file needs to be saved
  if [ ${#INCLIST[@]} -eq 0 ] && [ "${INCEXCFILE}" == '' ]; then
    EXCLUDEROOT=''
  else
    EXCLUDEROOT="--exclude=**"
  fi


  # Restore IFS
  IFS=$OLDIFS
}

duplicity_cleanup()
{
  echo "----------------[ Duplicity Cleanup ]----------------"
  if [[ "${CLEAN_UP_TYPE}" != "none" && -n ${CLEAN_UP_TYPE} && -n ${CLEAN_UP_VARIABLE} ]]; then
    {
      eval "${ECHO}" "${DUPLICITY}" "${CLEAN_UP_TYPE}" "${CLEAN_UP_VARIABLE}" "${STATIC_OPTIONS}" --force \
        "${ENCRYPT}" \
        "${DEST}"
    } || {
      BACKUP_ERROR=1
    }
    echo
  fi
  if [ -n "${REMOVE_INCREMENTALS_OLDER_THAN}" ] && [[ ${REMOVE_INCREMENTALS_OLDER_THAN} =~ ^[0-9]+$ ]]; then
    {
      eval "${ECHO}" "${DUPLICITY}" remove-all-inc-of-but-n-full "${REMOVE_INCREMENTALS_OLDER_THAN}" \
        "${STATIC_OPTIONS}" --force \
        "${ENCRYPT}" \
        "${DEST}"
    } || {
      BACKUP_ERROR=1
    }
    echo
  fi
}

duplicity_backup()
{
  {
    eval "${ECHO}" "${DUPLICITY}" "${OPTION}" "${VERBOSITY}" "${STATIC_OPTIONS}" \
    "${ENCRYPT}" \
    "${EXCLUDE}" \
    "${INCLUDE}" \
    "${EXCLUDEROOT}" \
    "${ROOT}" "${DEST}"
  } || {
    BACKUP_ERROR=1
  }
}

duplicity_cleanup_failed()
{
  {
    eval "${ECHO}" "${DUPLICITY}" "${OPTION}" "${VERBOSITY}" "${STATIC_OPTIONS}" \
    "${ENCRYPT}" \
    "${DEST}"
  } || {
    BACKUP_ERROR=1
  }
}

setup_passphrase()
{
  if [ -n "${GPG_ENC_KEY}" ] && [ -n "${GPG_SIGN_KEY}" ] && [ "${GPG_ENC_KEY}" != "${GPG_SIGN_KEY}" ]; then
    echo -n "Please provide the passphrase for decryption (GPG key 0x${GPG_ENC_KEY}): " >&3
    builtin read -s -r ENCPASSPHRASE
    echo -ne "\n" >&3
    PASSPHRASE=${ENCPASSPHRASE}
    export PASSPHRASE
  fi
}

backup_this_script()
{
  if [ "$(echo "${0}" | cut -c 1)" = "." ]; then
    SCRIPTFILE=$(echo "${0}" | cut -c 2-)
    SCRIPTPATH=$(pwd)${SCRIPTFILE}
  else
    SCRIPTPATH=$(command -v "${0}")
  fi
  TMPDIR=duplicity-backup-$(date +%Y-%m-%d)
  TMPFILENAME=${TMPDIR}.tar.gpg

  echo "You are backing up: " >&3
  echo "      1. ${SCRIPTPATH}" >&3

  if [ -n "${GPG_ENC_KEY}" ] && [ -n "${GPG_SIGN_KEY}" ]; then
    if [ "${GPG_ENC_KEY}" = "${GPG_SIGN_KEY}" ]; then
      echo "      2. GPG Secret encryption and sign key: ${GPG_ENC_KEY}" >&3
    else
      echo "      2. GPG Secret encryption key: ${GPG_ENC_KEY} and GPG secret sign key: ${GPG_SIGN_KEY}" >&3
    fi
  else
    echo "      2. GPG Secret encryption and sign key: none (symmetric encryption)" >&3
  fi

  if [ -n "${CONFIG}" ] && [ -f "${CONFIG}" ];
  then
    echo "      3. Config file: ${CONFIG}" >&3
  fi

  if [ -n "${INCEXCFILE}" ] && [ -f "${INCEXCFILE}" ];
  then
    echo "      4. Include/Exclude globbing file: ${INCEXCFILE}" >&3
  fi

  echo "Backup tarball will be encrypted and saved to: $(pwd)/${TMPFILENAME}" >&3
  echo >&3
  echo ">> Are you sure you want to do that ('yes' to continue)?" >&3
  read -r ANSWER
  if [ "${ANSWER}" != "yes" ]; then
    echo "You said << ${ANSWER} >> so I am exiting now." >&3
    echo -e "---------------------    END    ---------------------\n" >&5
    exit 1
  fi

  mkdir -p "${TMPDIR}"
  cp "${SCRIPTPATH}" "${TMPDIR}"/

  if [ -n "${CONFIG}" ] && [ -f "${CONFIG}" ];
  then
    cp "${CONFIG}" "${TMPDIR}"/
  fi

  if [ -n "${INCEXCFILE}" ] && [ -f "${INCEXCFILE}" ];
  then
    cp "${INCEXCFILE}" "${TMPDIR}"/
  fi

  echo "Encrypting tarball, choose a password you'll remember..." >&3
  tar -cf - "${TMPDIR}" | gpg -aco "${TMPFILENAME}"
  rm -Rf "${TMPDIR}"
  echo -e "\nIMPORTANT!!" >&3
  echo ">> To restore these files, run the following (remember your password):" >&3
  echo "gpg -d ${TMPFILENAME} | tar -xf -" >&3
  echo -e "\nYou may want to write the above down and save it with the file." >&3
}

# ##################################################
# ####        end of functions definition       ####
# ##################################################

check_variables

echo -e "--------    START DUPLICITY-BACKUP SCRIPT for ${HOSTNAME}   --------\n" >&5

echo -e "-------[ Program versions ]-------"
echo -e "duplicity-backup.sh ${DBSH_VERSION}"
echo -e "duplicity ${DUPLICITY_VERSION}"
echo -e "----------------------------------\n"

get_lock

INCLUDE=
EXCLUDE=
EXCLUDEROOT=

case "${COMMAND}" in
  "backup-script")
    backup_this_script
    exit 0
  ;;

  "full")
    OPTION="full"
    include_exclude
    duplicity_backup
    duplicity_cleanup
  ;;

  "verify")
    OLDROOT=${ROOT}
    ROOT=${DEST}
    DEST=${OLDROOT}
    OPTION="verify"

    echo -e "-------[ Verifying Source & Destination ]-------\n"
    include_exclude
    setup_passphrase
    echo -e "Attempting to verify now ...\n" >&3
    duplicity_backup
    echo

    OLDROOT=${ROOT}
    ROOT=${DEST}
    DEST=${OLDROOT}

    echo -e "Verify complete.\n" >&3
  ;;

  "cleanup")
    OPTION="cleanup"

    if [ -z "${DRY_RUN}" ]; then
      STATIC_OPTIONS="${STATIC_OPTIONS} --force"
    fi

    echo -e "-------[ Cleaning up Destination ]-------\n"
    setup_passphrase
    duplicity_cleanup_failed

    echo -e "Cleanup complete."
  ;;

  "restore")
    ROOT=${DEST}
    OPTION="restore"
    if [ -n "${TIME}" ]; then
      STATIC_OPTIONS="${STATIC_OPTIONS} --time ${TIME}"
    fi

    if [[ ! "${RESTORE_DEST}" ]]; then
      echo "Please provide a destination path (eg, /home/user/dir):" >&3
      read -r -e NEWDESTINATION
      DEST=${NEWDESTINATION}
      echo ">> You will restore from ${ROOT} to ${DEST}" >&3
      echo "Are you sure you want to do that ('yes' to continue)?" >&3
      read -r ANSWER
      if [[ "${ANSWER}" != "yes" ]]; then
        echo "You said << ${ANSWER} >> so I am exiting now." >&3
        echo -e "User aborted restore process ...\n" >&2
        echo -e "---------------------    END    ---------------------\n" >&5
        exit 1
      fi
    else
      DEST=${RESTORE_DEST}
    fi

    setup_passphrase
    echo "Attempting to restore now ..." >&3
    duplicity_backup
  ;;

  "restore-file"|"restore-dir")
    ROOT=${DEST}
    OPTION="restore"

    if [ -n "${TIME}" ]; then
      STATIC_OPTIONS="${STATIC_OPTIONS} --time ${TIME}"
    fi

    if [[ ! "${FILE_TO_RESTORE}" ]]; then
      echo "Which file or directory do you want to restore?" >&3
      echo "(give the path relative to the root of the backup eg, mail/letter.txt):" >&3
      read -r -e FILE_TO_RESTORE
      echo
    fi

    if [[ "${RESTORE_DEST}" ]]; then
      DEST=${RESTORE_DEST}
    else
      DEST=$(basename "${FILE_TO_RESTORE}")
    fi

    echo -e "YOU ARE ABOUT TO..." >&3
    echo -e ">> RESTORE: ${FILE_TO_RESTORE}" >&3
    echo -e ">> TO: ${DEST}" >&3
    echo -e "\nAre you sure you want to do that ('yes' to continue)?" >&3
    read -r ANSWER
    if [ "${ANSWER}" != "yes" ]; then
      echo "You said << ${ANSWER} >> so I am exiting now." >&3
      echo -e "User aborted restore process ...\n" >&2
      echo -e "---------------------    END    ---------------------\n" >&5
      exit 1
    fi

    FILE_TO_RESTORE="'${FILE_TO_RESTORE}'"
    DEST="'${DEST}'"

    setup_passphrase
    echo "Restoring now ..." >&3
    #use INCLUDE variable without creating another one
    INCLUDE="--file-to-restore ${FILE_TO_RESTORE}"
    duplicity_backup
  ;;

  "list-current-files")
    OPTION="list-current-files"

    if [ -n "${TIME}" ]; then
      STATIC_OPTIONS="${STATIC_OPTIONS} --time ${TIME}"
    fi

    # shellcheck disable=SC2086
    eval \
    "${DUPLICITY}" "${OPTION}" "${VERBOSITY}" "${STATIC_OPTIONS}" \
    ${ENCRYPT} \
    "${DEST}"
  ;;

  "collection-status")
    OPTION="collection-status"

    # shellcheck disable=SC2086
    eval \
    "${DUPLICITY}" "${OPTION}" "${VERBOSITY}" "${STATIC_OPTIONS}" \
    ${ENCRYPT} \
    "${DEST}"
  ;;

  "backup")
    include_exclude
    duplicity_backup
    duplicity_cleanup
  ;;

  *)
    echo -e "[Only show $(basename "$0") usage options]\n"
    usage
  ;;
esac

echo -e "---------    END DUPLICITY-BACKUP SCRIPT    ---------\n" >&5

if [ "${USAGE}" ]; then
  exit 0
fi

if [ "${BACKUP_ERROR}" ]; then
  BACKUP_STATUS="ERROR"
else
  BACKUP_STATUS="OK"
fi

# send email
[[ ${BACKUP_ERROR} || ! "$EMAIL_FAILURE_ONLY" = "yes" ]] && email_logfile

# send notification
[[ ${BACKUP_ERROR} || ! "$NOTIFICATION_FAILURE_ONLY" = "yes" ]] && send_notification

# remove old logfiles
# stops them from piling up infinitely
[[ -n "${REMOVE_LOGS_OLDER_THAN}" ]] && find "${LOGDIR}" -type f -mtime +"${REMOVE_LOGS_OLDER_THAN}" -delete

if [ "${ECHO}" ]; then
  echo "TEST RUN ONLY: Check the logfile for command output."
fi

unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_PROFILE
unset PASSPHRASE
unset SIGN_PASSPHRASE
unset BACKEND_PASSWORD

# restore stdout and stderr to their original values
# and close the other fd
exec 1>&6 2>&7 3>&- 4>&- 5>&- 6>&- 7>&-

# vim: set tabstop=2 shiftwidth=2 sts=2 autoindent smartindent:
