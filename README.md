# scholar-infra

scholars-ai 的部署编排：docker compose、部署脚本、密钥模板。架构见 [spec/SPEC-001](https://github.com/scholars-ai/spec/blob/main/specs/SPEC-001-architecture.md)。

## 结构

```
compose.local.yaml    本地开发：Postgres（pgvector+pgmq）一键起；--profile services 联调 core/agents 容器
compose.prod.yaml     生产（VPS）：Postgres + queue-specific Agents + Langfuse + OTel stack
observability/        Collector / Tempo / Prometheus / Grafana 配置、Dashboard 与告警
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

本地 Compose 默认同时启动可观测性依赖：

- Grafana: `http://127.0.0.1:3302`（本地默认 admin/admin）
- Prometheus: `http://127.0.0.1:9090`
- OTLP gRPC/HTTP: `127.0.0.1:4317/4318`，供宿主机运行的 Core/Agents 上报
- Tempo 只在容器网络开放

宿主机直接运行服务时设置：

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317 # Agents
# Core 同时接受 127.0.0.1:4317 或 http://127.0.0.1:4317
export OTEL_EXPORTER_OTLP_INSECURE=true
```

链路关系固定为：`Core/Agents -> Collector -> Tempo/Prometheus -> Grafana`。
LLM 的 prompt/output/token 明细仍在 Langfuse，Tempo Span 只保存
`langfuse.trace_id` 等低敏感属性，并由 Job Explorer Dashboard 跳转。

## E2E 验收基线（VPS）

提交并推送代码后，统一在 VPS 上执行隔离的 E2E，作为合并和发布前的验收基线；本机
E2E 仅用于快速开发反馈，不作为最终通过条件。运行入口为：

```bash
cd /root/scholars-ai/scholar-infra
git pull --ff-only --prune
./e2e/run.sh
```

E2E 使用独立的 Compose project（默认 `scholars-e2e`）、PostgreSQL、Fake AI 和
Core/Agents 服务，所有端口和 named volume 均与生产环境隔离，禁止连接生产数据库或
复用生产卷。脚本结束后默认清理 E2E 容器和卷；需要保留现场排查时才设置
`KEEP_E2E=1`，排查完成后手动执行：

```bash
docker compose -p scholars-e2e -f compose.local.yaml --profile e2e --profile services down -v --remove-orphans
```

验收应覆盖完整 workflow、节点输入输出快照、decision/replay 与幂等性，以及可观测性
停机隔离；脚本退出码为 `0` 才视为通过。E2E 完成后确认生产 Core/Postgres 容器未被
重启，且生产数据卷未发生变化。

## 可观测性运行原则

- Collector/Tempo/Prometheus 不可用不影响业务 job；SDK 使用异步批量导出。
- Tempo 不保存 prompt、模型完整输出、正文、URL、密钥或数据库 DSN。
- Prometheus label 只使用 queue/job type/status/provider/model/error type 等有限集合。
- Trace 保留 7 天，Metrics 保留 30 天；初期 pipeline job 100% 采样。
- Grafana 生产端口只绑定 `127.0.0.1:3302`，应由现有 nginx 加 TLS/认证后访问。
- 生产 Agents 按 `source_fetch`、`topic_scout`、`topic_evaluate`、`article_write`、`article_evaluate`、`memory_reflect` 分成六个进程，避免慢队列阻塞其他队列；每个进程仍使用独立数据库连接。Reflector 单独使用 600 秒 whole-job deadline。

已预置 Dashboard：Operations Overview、Job Explorer、Queues、LLM Operations。
已预置低流量友好的核心告警。磁盘水位告警仍由现有 `scripts/disk-guard.sh`
承担；若未来接入 node-exporter，再迁入 Prometheus 统一告警。

Queues Dashboard 的任务数量口径：

- `Waiting tasks`：尚未被 Worker 领取的可见消息；持续上升代表消费跟不上。
- `In-flight tasks`：已被 Worker 领取、正在 visibility timeout 内处理的消息。
- `Current tasks`：Waiting + In-flight；只有它为 0 才表示队列完全空闲。
- `Online worker slots`：当前在线的 queue-specific Worker 容量；不等于正在执行数，
  是否繁忙应同时对照 In-flight。
- `scholar_pgmq_total_messages`：队列自创建以来的累计投递数，不是当前队列深度。

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
./scripts/m1-audit.sh                         # M1 生产审计：产量、重复率、队列、Langfuse 对账
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

`cos_sync.py` 使用腾讯云官方 Python SDK（运行时需安装 `cos-python-sdk-v5`）而非 coscli——子账号只授对象级权限，
而 coscli 下载前会做桶级 HEAD 探测（需 `cos:HeadBucket`）。详见 ADR-004。
- 加密口令在 `secrets/backup.env`——**丢失则备份不可解，务必另存密码管理器**
- 恢复演练已实测（2026-08-10）：扩展、11 枚举、6 个 pgmq 队列、3 个 HNSW 索引、goose 版本全部还原
