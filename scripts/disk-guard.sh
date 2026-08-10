#!/usr/bin/env bash
# 磁盘水位告警（ADR-004 硬性要求）：> 阈值则输出告警行并非零退出。
# 由 cron 调用；输出进 /root/scholars-backups/disk-guard.log，非零退出让 cron 发本地邮件。
# 同时报告本项目自身的占用（pg 数据卷 + 备份目录），便于判断是不是我们吃掉的。
set -euo pipefail

THRESHOLD=${THRESHOLD:-85}
BACKUP_DIR=${BACKUP_DIR:-/root/scholars-backups}

used=$(df --output=pcent / | tail -1 | tr -dc '0-9')
avail=$(df -h --output=avail / | tail -1 | tr -d ' ')

vol_path=$(docker volume inspect scholars-prod_pgdata --format '{{.Mountpoint}}' 2>/dev/null || true)
pg_size=$([ -n "$vol_path" ] && du -sh "$vol_path" 2>/dev/null | cut -f1 || echo "n/a")
bk_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "n/a")

line="$(date -u +%FT%TZ) disk=${used}% avail=${avail} pgdata=${pg_size} backups=${bk_size}"

if [ "$used" -ge "$THRESHOLD" ]; then
    echo "ALERT $line (threshold ${THRESHOLD}%)"
    exit 1
fi
echo "OK $line"
