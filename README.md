# scholar-infra

scholars-ai 的部署编排：docker compose、部署脚本、密钥模板。架构见 [spec/SPEC-001](https://github.com/scholars-ai/spec/blob/main/specs/SPEC-001-architecture.md)。

## 结构

```
compose.local.yaml    本地开发：Postgres（pgvector+pgmq）一键起；--profile services 联调 core/agents 容器
compose.prod.yaml     生产（VPS）：core + agents + langfuse；DB 在 Supabase，不在 compose 内
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
