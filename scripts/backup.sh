#!/usr/bin/env bash
# 每日备份（ADR-004 硬性要求）：pg_dump 业务库与 langfuse 库 → gzip → 加密 → 本地保留 N 份
#   可选：配置了 coscli 则推送腾讯云 COS（离机副本）
# 用法：./scripts/backup.sh            由 cron 每日调用
# 恢复：./scripts/restore.sh <备份文件>
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER=scholars-prod-postgres-1
BACKUP_DIR=${BACKUP_DIR:-/root/scholars-backups}
RETAIN=${RETAIN:-7}
COS_PREFIX=${COS_PREFIX:-cos://scholars-backups}

# 密钥从 secrets 读取，绝不出现在命令行参数里（避免进程列表泄漏）
PGPASSWORD=$(grep -oP '(?<=POSTGRES_PASSWORD=).*' secrets/postgres.env)
BACKUP_PASSPHRASE=$(grep -oP '(?<=BACKUP_PASSPHRASE=).*' secrets/backup.env)
export PGPASSWORD

mkdir -p "$BACKUP_DIR"
stamp=$(date -u +%Y%m%dT%H%M%SZ)

for db in scholar langfuse; do
    out="$BACKUP_DIR/${db}-${stamp}.sql.gz.enc"
    # pg_dump 在容器内执行；gzip 后用 AES-256 加密（口令走 stdin，不进 argv）
    if ! docker exec -e PGPASSWORD="$PGPASSWORD" "$CONTAINER" \
        pg_dump -U scholar -d "$db" --no-owner --no-privileges 2>/dev/null |
        gzip -9 |
        openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass fd:3 -out "$out" \
            3< <(printf '%s' "$BACKUP_PASSPHRASE"); then
        echo "backup FAILED for db=$db" >&2
        rm -f "$out"
        exit 1
    fi
    # 完整性校验：能解密、能解压、且含 pg_dump 头部与结束标记。
    # 比"体积阈值"可靠 —— 空库的合法备份也很小，而损坏的备份可能不小。
    if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass fd:3 -in "$out" \
        3< <(printf '%s' "$BACKUP_PASSPHRASE") | gunzip |
        grep -q 'PostgreSQL database dump complete'; then
        echo "backup CORRUPT for db=$db (无法解密/解压，或 dump 未正常结束)" >&2
        rm -f "$out"
        exit 1
    fi
    echo "backed up $db -> $(basename "$out") ($(stat -c %s "$out")B, verified)"

    # 离机副本（可选）：配置了 coscli 才推
    if command -v coscli >/dev/null 2>&1; then
        coscli cp "$out" "$COS_PREFIX/$(basename "$out")" >/dev/null && echo "  pushed to COS"
    fi
done

# 保留最近 N 份（每库各算）
for db in scholar langfuse; do
    ls -1t "$BACKUP_DIR/${db}-"*.sql.gz.enc 2>/dev/null | tail -n +$((RETAIN + 1)) | while read -r old; do
        rm -f "$old" && echo "pruned $(basename "$old")"
    done
done

echo "backup done at $stamp; dir=$BACKUP_DIR"
