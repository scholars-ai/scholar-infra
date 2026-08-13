# scholar-infra

scholars-ai 的部署编排：docker compose、部署脚本、密钥模板。架构见 [spec/SPEC-001](https://github.com/scholars-ai/spec/blob/main/specs/SPEC-001-architecture.md)。

## 结构

```
compose.local.yaml    本地开发：Postgres（pgvector+pgmq）一键起；--profile services 联调 core/agents 容器
compose.prod.yaml     生产（VPS）：自托管 Postgres + core + agents + Langfuse
postgres/Dockerfile   本地开发库镜像（pgvector 官方镜像 + pgmq 扩展）
deploy.sh             VPS 部署：./deploy.sh <core|agents|all> <version>（拉 GHCR 镜像滚动更新）
secrets/*.example     密钥模板。真实密钥只存在于 VPS 部署工作区，绝不入库
```

## 本地开发

```bash
docker compose -f compose.local.yaml up -d          # 只起数据库
# core:   cd ../scholar-core   && make migrate-up && make run
# agents: cd ../scholar-agents && uv run python -m scholar_agents.worker.consumer
```

## 密钥纪律（硬性）

- `secrets/` 下除 `*.example` 全部 gitignore；
- 生产密钥只存在于 VPS 部署工作区（本仓库在 VPS 上的检出）；
- CI 密钥用 GitHub Actions secrets；仓库三层防线：.gitignore + gitleaks CI + GitHub push protection。

## 生产数据库（自托管，ADR-004）

```bash
docker compose -f compose.prod.yaml up -d --build postgres   # 首次
cd ../scholar-core && source ../scholar-infra/secrets/local-dsn.sh \
  && DATABASE_URL="$DATABASE_URL_LOCAL" make migrate-up      # 迁移
```

- 监听 `127.0.0.1:5434`（5433 已被 operation-content-platform 占用）
- Langfuse 监听 `127.0.0.1:3301`（3000 已被 operation-content-platform 占用）
- 业务库 `scholar` + Langfuse 库 `langfuse` 同实例；扩展 pgvector 0.8.6 / pgmq 1.12 由 `postgres/initdb/` 首次初始化
- 数据卷 `scholars-prod_pgdata`（named volume，compose 重建不丢数据）

## 备份与恢复（ADR-004 硬性要求）

```bash
./scripts/backup.sh                          # cron 每日 03:47 自动执行
./scripts/restore.sh <备份文件> restore_drill  # 恢复演练（勿直接覆盖生产库）
./scripts/disk-guard.sh                      # 磁盘水位，cron 每 6h
```

- 备份 = `pg_dump` → gzip → AES-256 加密；**写完立即解密校验 dump 完整性**，损坏即失败并删除残件
- 本地保留 7 份于 `/root/scholars-backups`；**同时推 COS 离机副本**（`scholars-backups-1400089319`，
  ap-singapore 与 VPS 同地域走内网），远端同样保留 7 份。上传后回读 Content-Length 校验。
- 离机上传失败只告警，不使本次备份失败（本地副本此时已完成并验证）
- 加密口令在 `secrets/backup.env`——**丢失则备份不可解，务必另存密码管理器**

### 从 COS 恢复（本地副本也丢了的场景）

```bash
./scripts/cos_sync.py list                                   # 看远端有哪些副本
./scripts/restore.sh cos:db/scholar-<时间戳>.sql.gz.enc restore_drill
```

`cos_sync.py` 用腾讯云官方 Python SDK 而非 coscli——子账号只授对象级权限，
而 coscli 下载前会做桶级 HEAD 探测（需 `cos:HeadBucket`）。详见 ADR-004。
- 加密口令在 `secrets/backup.env`——**丢失则备份不可解，务必另存密码管理器**
- 恢复演练已实测（2026-08-10）：扩展、11 枚举、6 个 pgmq 队列、3 个 HNSW 索引、goose 版本全部还原
