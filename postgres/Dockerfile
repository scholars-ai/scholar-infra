# 本地开发数据库：pgvector 官方镜像 + pgmq 扩展（纯 SQL 扩展，make install 即可）。
# 生产不用本镜像 —— 生产库是 Supabase（pgmq/pgvector 原生支持）。
FROM pgvector/pgvector:0.8.6-pg17-trixie

ARG PGMQ_VERSION=v1.12.0
RUN apt-get update \
    && apt-get install -y --no-install-recommends git make postgresql-server-dev-17 ca-certificates \
    && git clone --depth 1 --branch ${PGMQ_VERSION} https://github.com/pgmq/pgmq.git /tmp/pgmq \
    && make -C /tmp/pgmq/pgmq-extension install \
    && rm -rf /tmp/pgmq \
    && apt-get purge -y git make postgresql-server-dev-17 \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*
