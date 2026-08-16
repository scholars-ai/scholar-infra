#!/usr/bin/env bash
# 部署脚本骨架（M1 上 VPS 时完善）。
# 用法：./deploy.sh <core|agents|all> <version>
# 前置：本目录为 VPS 上的部署工作区，secrets/ 已就位（不在 git 内）。
set -euo pipefail
cd "$(dirname "$0")"

SERVICE="${1:?usage: deploy.sh <core|agents|all> <version>}"
VERSION="${2:?usage: deploy.sh <core|agents|all> <version>}"

deploy_one() {
  local svc="$1" ver="$2"
  case "$svc" in
    core)   export CORE_VERSION="$ver" ;;
    agents) export AGENTS_VERSION="$ver" ;;
    *) echo "unknown service: $svc" >&2; exit 1 ;;
  esac
  local services=("$svc")
  if [ "$svc" = "agents" ]; then
    services=(agents-source-fetch agents-topic-scout agents-topic-evaluate)
  fi
  docker compose -f compose.prod.yaml pull "${services[@]}"
  docker compose -f compose.prod.yaml up -d "${services[@]}"
  echo "deployed $svc @ $ver"
}

if [ "$SERVICE" = "all" ]; then
  deploy_one core "$VERSION"
  deploy_one agents "$VERSION"
else
  deploy_one "$SERVICE" "$VERSION"
fi

docker compose -f compose.prod.yaml ps
