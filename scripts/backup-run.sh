#!/bin/sh
# Offen/docker-volume-backup v2.50.1 has no unchanged-source
# skip or total-size cap; this gates its backup command and caps local copies only.
set -eu

archive_dir=${BACKUP_ARCHIVE:-/archive}
source_dir=${BACKUP_SOURCES:-/backup}
state_file="$archive_dir/.sn2-last-backup.sha256"
prefix=${BACKUP_PRUNING_PREFIX:-sn2-saves-}

complete_archives() {
  find "$archive_dir" -maxdepth 1 -type f -print | awk -v prefix="$prefix" '
    {
      name = $0; sub(/^.*\//, "", name)
      if (substr(name, 1, length(prefix)) != prefix) next
      suffix = substr(name, length(prefix) + 1)
      if (suffix ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}\.tar\.gz(\.gpg|\.age)?$/) print $0
    }' | LC_ALL=C sort
}

fingerprint() {
  find "$source_dir" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s  ' "${file#"$source_dir"/}"
    sha256sum "$file" | cut -d' ' -f1
  done | sha256sum | cut -d' ' -f1
}

cap_local_archives() {
  [ -n "${BACKUP_MAX_TOTAL_MB:-}" ] || return 0
  case $BACKUP_MAX_TOTAL_MB in *[!0-9]*|'')
    echo "backup: BACKUP_MAX_TOTAL_MB must be a whole number" >&2; return 1 ;;
  esac
  [ "$BACKUP_MAX_TOTAL_MB" -ne 0 ] || return 0
  limit_bytes=$((BACKUP_MAX_TOTAL_MB * 1024 * 1024))
  archives=$(complete_archives)
  [ -n "$archives" ] || return 0
  newest=$(printf '%s\n' "$archives" | tail -n 1)
  total_bytes=$(printf '%s\n' "$archives" | while IFS= read -r archive; do stat -c '%s' "$archive"; done |
    awk '{ n += $1 } END { print n + 0 }')
  printf '%s\n' "$archives" | while IFS= read -r archive; do
      [ "$total_bytes" -le "$limit_bytes" ] && break
      if [ "$archive" = "$newest" ]; then
        echo "backup: newest archive exceeds ${BACKUP_MAX_TOTAL_MB} MB; keeping it"
        break
      fi
      echo "backup: removing oldest local archive $(basename "$archive") to stay under ${BACKUP_MAX_TOTAL_MB} MB"
      archive_bytes=$(stat -c '%s' "$archive")
      rm -f -- "$archive" && total_bytes=$((total_bytes - archive_bytes))
    done
}

run_backup() {
  mkdir -p "$archive_dir"
  current=$(fingerprint)
  previous=$(sed -n '1p' "$state_file" 2>/dev/null || true)
  previous_archive=$(sed -n '2p' "$state_file" 2>/dev/null || true)
  if [ "${BACKUP_SKIP_UNCHANGED:-true}" = true ] &&
     [ "$previous" = "$current" ] && [ -n "$previous_archive" ] &&
     complete_archives | grep -Fxq "$archive_dir/$previous_archive"; then
    echo "backup: staged saves unchanged; no archive created"
    cap_local_archives
    return
  fi
  ${SN2_BACKUP_COMMAND:-/usr/bin/backup}
  newest=$(complete_archives | tail -n 1)
  printf '%s\n%s\n' "$current" "${newest##*/}" >"$state_file"
  cap_local_archives
}

if [ "${1:-}" = --run ]; then
  run_backup
  exit
fi
[ "$#" -eq 0 ] || exec /usr/bin/backup "$@"

cron=${BACKUP_CRON_EXPRESSION:-'*/30 * * * *'}
printf '%s %s\n' "$cron" '/usr/local/bin/sn2-backup --run' >/etc/crontabs/root
exec crond -f -l 2
