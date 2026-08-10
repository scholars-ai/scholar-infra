#!/bin/bash
# 首次初始化（仅在数据卷为空时执行）：
#   1. 业务库启用 pgvector + pgmq 扩展
#   2. 为 Langfuse 建独立 database（ADR-004：同实例、不同 database）
# 注意：业务表结构由 scholar-core 的 goose 迁移负责，这里只做扩展与建库。
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
    create extension if not exists vector;
    create extension if not exists pgmq;
SQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
    create database ${LANGFUSE_DB:-langfuse} owner ${POSTGRES_USER};
SQL

echo "initdb: extensions ready on ${POSTGRES_DB}; database ${LANGFUSE_DB:-langfuse} created"
