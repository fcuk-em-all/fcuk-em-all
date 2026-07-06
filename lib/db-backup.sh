#!/usr/bin/env bash
# =============================================================================
# lib/db-backup.sh - daily DATABASE backups for the file-backed apps (33.sh).
#
# Backs up DATABASES/CONFIG ONLY - never the media files (those are user-owned
# originals or re-fetchable content, not what a backup must protect).
#  * Immich (Postgres): pg_dump --clean --if-exists | gzip  -> immich-*.sql.gz
#    (a raw copy of a live Postgres data dir is NOT reliably restorable; pg_dump is)
#  * Kavita / Navidrome / Audiobookshelf / Jellyfin (SQLite): SQLite ONLINE backup
#    API via lib/db-sqlite-backup.py -> *-*.db.gz  (consistent hot copy of the live
#    WAL db, NO app downtime - a plain cp of a mid-write WAL db is not safe).
#    NOTE: Jellyfin is beyond the four named apps but is the same SQLite pattern and
#    the most user-facing app (watch state/users) - included on purpose, flagged.
#
# RETENTION: keep 7 daily + 4 weekly (the Sunday daily, copied) per app, prune the
# rest. 7 daily = a week of point-in-time recovery (catch a corruption within days);
# 4 weekly extends coverage to ~1 month for slower-noticed issues; bounded growth.
#
# Shares the importer's lock (flock -w 300: WAIT, never race the 60s sweep / prune /
# itself). Logs to stdout (cron -> db-backup.log). Secrets never printed.
#   db-backup.sh              run a full backup cycle + retention
#   db-backup.sh --prune-only run only the retention prune (no new backup)
# =============================================================================
set -uo pipefail   # NOT -e: one app failing must not abort the others
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
PROOT="$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
BK="${PROOT}/backups/db"
IMG="fcuk-em-all/importer:local"
PYBK="${PROOT}/lib/db-sqlite-backup.py"
KEEP_DAILY=7
KEEP_WEEKLY=4
APPS="immich kavita navidrome audiobookshelf jellyfin"
log(){ printf '[%s] [db-backup] %s\n' "$(date '+%F %T')" "$*"; }

# retention: keep the newest N of each <app>-<kind>-* set, prune older (by mtime)
prune_retention(){
  local app kind keep f
  for app in $APPS; do
    for kv in "daily ${KEEP_DAILY}" "weekly ${KEEP_WEEKLY}"; do
      set -- $kv; kind="$1"; keep="$2"
      ls -1t "${BK}/${app}-${kind}-"* 2>/dev/null | tail -n +"$((keep + 1))" | while IFS= read -r f; do
        rm -f "$f" && log "retention: pruned $(basename "$f")"
      done
    done
  done
}

mkdir -p "$BK"
exec 9>/tmp/sf-importer.lock
flock -w 300 9 || { log "could not acquire shared lock within 300s; skip this cycle"; exit 0; }

if [ "${1:-}" = "--prune-only" ]; then
  log "prune-only: applying retention (keep ${KEEP_DAILY} daily + ${KEEP_WEEKLY} weekly per app)"
  prune_retention
  log "prune-only done"
  exit 0
fi

TS="$(date +%Y%m%d_%H%M%S)"; DOW="$(date +%u)"   # 7 = Sunday
rc=0
log "starting backup cycle -> ${BK}"

# --- Immich / Postgres ---------------------------------------------------------
pgf="${BK}/immich-daily-${TS}.sql.gz"
if docker exec fcuk-em-all-immich-postgres pg_dump -U immich -d immich --clean --if-exists 2>/dev/null | gzip -c > "$pgf"; then
  # capture first lines into a var THEN match - never `| head | grep -q`, which
  # SIGPIPEs zcat and (under pipefail) falsely fails on a perfectly valid dump.
  hdr="$(zcat "$pgf" 2>/dev/null | head -5 || true)"
  case "$hdr" in
    *"PostgreSQL database dump"*) log "immich: pg_dump OK -> $(basename "$pgf") ($(du -h "$pgf" 2>/dev/null | cut -f1))" ;;
    *) log "immich: ERROR - dump lacks the PostgreSQL header; removing bad file"; rm -f "$pgf"; rc=1 ;;
  esac
else
  log "immich: ERROR - pg_dump failed"; rm -f "$pgf"; rc=1
fi

# --- SQLite apps ---------------------------------------------------------------
sqlite_backup(){ # <name> <container> <db-path-in-container>
  local name="$1" container="$2" db="$3" out="${BK}/${1}-daily-${TS}.db.gz"
  if docker run --rm --volumes-from "$container" -v "${BK}:/out" -v "${PYBK}:/bk.py:ro" \
       --entrypoint python "$IMG" /bk.py "$db" "/out/${name}-daily-${TS}.db.gz" >/dev/null 2>&1; then
    log "${name}: SQLite online .backup + integrity_check OK -> $(basename "$out") ($(du -h "$out" 2>/dev/null | cut -f1))"
  else
    log "${name}: ERROR - SQLite backup or integrity_check failed"; rm -f "$out" "${BK}/${name}-daily-${TS}.db.gz.tmp"; rc=1
  fi
}
sqlite_backup kavita         fcuk-em-all-kavita         /config/kavita.db
sqlite_backup navidrome      fcuk-em-all-navidrome      /data/navidrome.db
sqlite_backup audiobookshelf fcuk-em-all-audiobookshelf /config/absdatabase.sqlite
sqlite_backup jellyfin       fcuk-em-all-jellyfin       /config/data/jellyfin.db

# --- weekly snapshot (Sunday): copy each just-made daily to a weekly file ------
if [ "$DOW" = 7 ]; then
  for f in "${BK}"/*-daily-"${TS}".*; do
    [ -e "$f" ] || continue
    cp -p "$f" "$(echo "$f" | sed 's/-daily-/-weekly-/')" && log "weekly snapshot: $(basename "$f" | sed 's/-daily-/-weekly-/')"
  done
fi

prune_retention
log "backup cycle done (rc=${rc}); ${BK} now holds $(ls -1 "${BK}" 2>/dev/null | wc -l | tr -d ' ') files ($(du -sh "${BK}" 2>/dev/null | cut -f1))"
exit "$rc"
