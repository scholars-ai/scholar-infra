#!/usr/bin/env bash
# 从加密备份恢复（ADR-004 要求恢复流程必须实测过）。
# 用法：./scripts/restore.sh <备份文件.sql.gz.enc> [目标库名]
#   目标库默认从文件名推断；建议先恢复到临时库验证，再决定是否覆盖生产库。
set -euo pipefail
cd "$(dirname "$0")/.."

FILE=${1:?usage: restore.sh <backup.sql.gz.enc> [target_db]}
[ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 1; }
DEFAULT_DB=$(basename "$FILE" | sed -E 's/-[0-9]{8}T[0-9]{6}Z\.sql\.gz\.enc$//')
TARGET_DB=${2:-$DEFAULT_DB}
CONTAINER=scholars-prod-postgres-1

PGPASSWORD=$(grep -oP '(?<=POSTGRES_PASSWORD=).*' secrets/postgres.env)
BACKUP_PASSPHRASE=$(grep -oP '(?<=BACKUP_PASSPHRASE=).*' secrets/backup.env)

echo "restoring $(basename "$FILE") -> database '$TARGET_DB'"
if [ "$TARGET_DB" = "scholar" ] || [ "$TARGET_DB" = "langfuse" ]; then
    echo "WARNING: '$TARGET_DB' 是生产库。确认要覆盖？输入 yes 继续："
    read -r confirm
    [ "$confirm" = "yes" ] || { echo "aborted"; exit 1; }
fi

# 目标库不存在则创建
docker exec -e PGPASSWORD="$PGPASSWORD" "$CONTAINER" \
    psql -U scholar -d postgres -tAc \
    "select 1 from pg_database where datname='$TARGET_DB'" | grep -q 1 ||
    docker exec -e PGPASSWORD="$PGPASSWORD" "$CONTAINER" \
        createdb -U scholar "$TARGET_DB"

openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass fd:3 -in "$FILE" \
    3< <(printf '%s' "$BACKUP_PASSPHRASE") |
    gunzip |
    docker exec -i -e PGPASSWORD="$PGPASSWORD" "$CONTAINER" \
        psql -U scholar -d "$TARGET_DB" -q --set ON_ERROR_STOP=on

echo "restore ok. 校验："
docker exec -e PGPASSWORD="$PGPASSWORD" "$CONTAINER" psql -U scholar -d "$TARGET_DB" -tAc \
    "select 'tables=' || count(*) from pg_tables where schemaname='public'"
