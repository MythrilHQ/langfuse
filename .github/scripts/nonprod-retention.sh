#!/usr/bin/env bash
# Deletes trace data older than RETENTION_DAYS for the listed non-production
# projects on the production Langfuse host.
#
# Langfuse's own data retention (worker/src/ee/dataRetention) only runs with an
# Enterprise license. This mirrors what that job deletes:
#   - lightweight DELETE on traces/scores (timestamp), observations and
#     events_full/events_core (start_time), blob_storage_file_log (created_at)
#   - raw ingestion event files in the event bucket
# Raw event files are removed by object age, not via blob_storage_file_log,
# because that table has a 30-day TTL and loses track of older files.
#
# Required env: COMPOSE_PROJECT_NAME, RETENTION_DAYS, PROJECT_IDS,
#               PROTECTED_PROJECT_IDS, EVENT_BUCKET, EVENT_PREFIX, DRY_RUN
set -euo pipefail

: "${COMPOSE_PROJECT_NAME:?}" "${RETENTION_DAYS:?}" "${PROJECT_IDS:?}"
: "${PROTECTED_PROJECT_IDS:?}" "${EVENT_BUCKET:?}" "${EVENT_PREFIX:?}"
DRY_RUN="${DRY_RUN:-true}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || [ "$RETENTION_DAYS" -lt 7 ]; then
  echo "::error::RETENTION_DAYS must be an integer >= 7, got '$RETENTION_DAYS'" >&2
  exit 1
fi

for pid in $PROJECT_IDS; do
  if ! [[ "$pid" =~ ^[a-z0-9-]+$ ]]; then
    echo "::error::Invalid project id '$pid'" >&2
    exit 1
  fi
  for protected in $PROTECTED_PROJECT_IDS; do
    if [ "$pid" = "$protected" ]; then
      echo "::error::Refusing to clean protected project '$pid'" >&2
      exit 1
    fi
  done
done

container() {
  local ids count
  ids=$(docker ps -q \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
    --filter "label=com.docker.compose.service=$1")
  count=$(printf '%s\n' "$ids" | grep -c . || true)
  if [ "$count" != "1" ]; then
    echo "::error::Expected one running '$1' container in ${COMPOSE_PROJECT_NAME}, found ${count}" >&2
    exit 1
  fi
  printf '%s' "$ids"
}

CH=$(container clickhouse)
PG=$(container postgres)
MINIO=$(container minio)

# shellcheck disable=SC2016 # expanded inside the container
ch() { docker exec -i "$CH" sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery'; }
# shellcheck disable=SC2016 # expanded inside the container
pg() { docker exec -i "$PG" sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -v ON_ERROR_STOP=1'; }
# shellcheck disable=SC2016 # expanded inside the container
mc_run() {
  docker exec -i -e MC_CONFIG_DIR=/tmp/.mc-retention "$MINIO" sh -c \
    'mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && mc "$@"' mc "$@"
}

CUTOFF=$(date -u -d "-${RETENTION_DAYS} days" '+%Y-%m-%d %H:%M:%S')
echo "Retention ${RETENTION_DAYS} days, cutoff ${CUTOFF} UTC, dry run: ${DRY_RUN}"
echo "Disk before: $(df -h / | tail -1)"

{
  echo "### Non-production trace retention"
  echo
  echo "Cutoff: \`${CUTOFF} UTC\` (${RETENTION_DAYS} days). Dry run: \`${DRY_RUN}\`."
  echo
  echo "| Project | Table | Rows older than cutoff | Action |"
  echo "|---|---|---|---|"
} >> "$SUMMARY"

TABLES="traces:timestamp observations:start_time scores:timestamp events_full:start_time events_core:start_time blob_storage_file_log:created_at"

for pid in $PROJECT_IDS; do
  name=$(echo "SELECT name FROM projects WHERE id = '${pid}' AND deleted_at IS NULL" | pg)
  if [ -z "$name" ]; then
    echo "::warning::Project ${pid} not found or deleted; skipping"
    continue
  fi
  echo "== ${name} (${pid})"

  # Raw ingestion event files first, as Langfuse does, so no file outlives its rows.
  for prefix in "${EVENT_PREFIX}${pid}/" "${EVENT_PREFIX}otel/${pid}/"; do
    path="local/${EVENT_BUCKET}/${prefix}"
    files=$(mc_run find "$path" --older-than "${RETENTION_DAYS}d" 2>/dev/null | grep -c . || true)
    action="none"
    if [ "$files" -gt 0 ] && [ "$DRY_RUN" != "true" ]; then
      mc_run rm --recursive --force --older-than "${RETENTION_DAYS}d" "$path" >/dev/null
      action="deleted"
    elif [ "$files" -gt 0 ]; then
      action="would delete"
    fi
    echo "  minio ${prefix}: ${files} files older than cutoff (${action})"
    echo "| ${name} | \`${prefix}\` files | ${files} | ${action} |" >> "$SUMMARY"
  done

  for entry in $TABLES; do
    table="${entry%%:*}"
    column="${entry##*:}"
    rows=$(echo "SELECT count() FROM ${table} WHERE project_id = '${pid}' AND ${column} < '${CUTOFF}' FORMAT TSV" | ch)
    action="none"
    if [ "$rows" -gt 0 ] && [ "$DRY_RUN" != "true" ]; then
      echo "DELETE FROM ${table} WHERE project_id = '${pid}' AND ${column} < '${CUTOFF}'" | ch
      action="deleted"
    elif [ "$rows" -gt 0 ]; then
      action="would delete"
    fi
    echo "  ${table}: ${rows} rows older than cutoff (${action})"
    echo "| ${name} | ${table} | ${rows} | ${action} |" >> "$SUMMARY"
  done
done

echo "Disk after: $(df -h / | tail -1)"
{
  echo
  echo "Disk after: \`$(df -h / | tail -1)\`"
  echo
  echo "Lightweight deletes hide rows at once; ClickHouse frees their disk space in later merges. MinIO frees deleted files within minutes."
} >> "$SUMMARY"
