#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT=scholars-e2e
COMPOSE=(docker compose -p "$PROJECT" -f compose.local.yaml --profile e2e --profile services)
export POSTGRES_HOST_PORT="${E2E_POSTGRES_PORT:-55432}"
export CORE_HOST_PORT="${E2E_CORE_PORT:-58080}"
export GRAFANA_HOST_PORT="${E2E_GRAFANA_PORT:-53302}"
export PROMETHEUS_HOST_PORT="${E2E_PROMETHEUS_PORT:-59090}"
export OTEL_GRPC_HOST_PORT="${E2E_OTEL_GRPC_PORT:-54317}"
export OTEL_HTTP_HOST_PORT="${E2E_OTEL_HTTP_PORT:-54318}"
export OTEL_HEALTH_HOST_PORT="${E2E_OTEL_HEALTH_PORT:-51333}"
DATABASE_URL="postgres://scholar:scholar@127.0.0.1:${POSTGRES_HOST_PORT}/scholar?sslmode=disable"

cleanup() {
  if [ "${KEEP_E2E:-0}" != "1" ]; then
    "${COMPOSE[@]}" down -v --remove-orphans
  fi
}
trap cleanup EXIT

wait_http() {
  local url="$1"
  for _ in $(seq 1 60); do
    if curl --silent --fail "$url" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for $url" >&2
  return 1
}

wait_sql() {
  local sql="$1" expected="$2"
  for _ in $(seq 1 90); do
    value=$("${COMPOSE[@]}" exec -T postgres psql -U scholar -d scholar -Atc "$sql")
    if [ "$value" = "$expected" ]; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for SQL result $expected: $sql" >&2
  return 1
}

wait_postgres() {
  for _ in $(seq 1 60); do
    if "${COMPOSE[@]}" exec -T postgres pg_isready -U scholar -d scholar >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "timed out waiting for E2E PostgreSQL" >&2
  return 1
}

"${COMPOSE[@]}" down -v --remove-orphans
"${COMPOSE[@]}" up -d --build postgres fake-ai tempo prometheus otel-collector grafana
wait_postgres
wait_http "http://127.0.0.1:${OTEL_HEALTH_HOST_PORT}/"
wait_http "http://127.0.0.1:${PROMETHEUS_HOST_PORT}/-/ready"

DATABASE_URL="$DATABASE_URL" make -C ../scholar-core migrate-up
"${COMPOSE[@]}" up -d --build core agents-e2e
wait_http "http://127.0.0.1:${CORE_HOST_PORT}/api/healthz"
wait_http "http://127.0.0.1:${GRAFANA_HOST_PORT}/api/health"

manual_response=$(curl --silent --fail \
  -H 'Content-Type: application/json' \
  -d '{"title":"Manual E2E Topic","angle":"A deterministic angle","summary":"Cross-repository test","targetPlatforms":["xiaohongshu","zhihu","wechat"]}' \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/topics")
manual_topic_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$manual_response")
wait_sql "select status::text from topics where id = '$manual_topic_id'" scored

curl --silent --fail -X POST \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/topics/${manual_topic_id}/approve" >/dev/null
wait_sql "select status::text from topics where id = '$manual_topic_id'" written
wait_sql "select count(*)::text from articles where topic_id = '$manual_topic_id'" 3
wait_sql "select count(distinct platform)::text from articles where topic_id = '$manual_topic_id'" 3
wait_sql "select count(*)::text from schedule_runs where schedule_key like 'article_evaluate:%' and msg_id is not null" 3
wait_sql "select count(*)::text from pgmq.q_article_evaluate" 3

curl --silent --fail \
  -H 'Content-Type: application/json' \
  -d '{"url":"http://fake-ai:8081/article","note":"cross-repository e2e"}' \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/ingest/url" >/dev/null
wait_sql "select coalesce((select t.status::text from topics t join raw_items r on r.id = any(t.raw_item_ids) where r.url = 'http://fake-ai:8081/article' order by t.created_at desc limit 1), '')" scored

correlation_id=$("${COMPOSE[@]}" exec -T postgres psql -U scholar -d scholar -Atc \
  "select correlation_id from raw_items where url = 'http://fake-ai:8081/article' order by created_at desc limit 1")
test -n "$correlation_id"

trace_query="{ span.correlation.id = \"$correlation_id\" }"
trace_id=""
trace_detail=""
for _ in $(seq 1 60); do
  trace_result=$(curl --silent --fail --get \
    --data-urlencode "q=$trace_query" \
    "http://127.0.0.1:${GRAFANA_HOST_PORT}/api/datasources/proxy/uid/tempo/api/search")
  trace_ids=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(" ".join(item.get("traceID", "") for item in data.get("traces", []) if item.get("traceID")))' <<<"$trace_result")
  for trace_candidate in $trace_ids; do
    candidate_detail=$(curl --silent --fail \
      "http://127.0.0.1:${GRAFANA_HOST_PORT}/api/datasources/proxy/uid/tempo/api/traces/$trace_candidate")
    if grep -q 'correlation.id' <<<"$candidate_detail" && grep -q 'langfuse.trace_id' <<<"$candidate_detail"; then
      trace_id="$trace_candidate"
      trace_detail="$candidate_detail"
      break 2
    fi
  done
  sleep 2
done
if [ -z "$trace_id" ]; then
  echo "timed out waiting for Tempo trace with correlation $correlation_id and Langfuse linkage" >&2
  exit 1
fi
grep -q 'correlation.id' <<<"$trace_detail"
grep -q 'langfuse.trace_id' <<<"$trace_detail"

agent_metric_found=""
core_metric_found=""
queue_depth_metrics_found=""
for _ in $(seq 1 30); do
  agent_metric_result=$(curl --silent --fail --get \
    --data-urlencode 'query=scholar_agent_jobs_completed_total' \
    "http://127.0.0.1:${PROMETHEUS_HOST_PORT}/api/v1/query")
  core_metric_result=$(curl --silent --fail --get \
    --data-urlencode 'query=scholar_pgmq_total_messages' \
    "http://127.0.0.1:${PROMETHEUS_HOST_PORT}/api/v1/query")
  queue_depth_metrics_result=$(curl --silent --fail --get \
    --data-urlencode 'query=count(scholar_pgmq_visible_messages) + count(scholar_pgmq_in_flight_messages) + count(scholar_pgmq_current_messages)' \
    "http://127.0.0.1:${PROMETHEUS_HOST_PORT}/api/v1/query")
  agent_metric_found=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print("yes" if data.get("data", {}).get("result") else "")' <<<"$agent_metric_result")
  core_metric_found=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print("yes" if data.get("data", {}).get("result") else "")' <<<"$core_metric_result")
  queue_depth_metrics_found=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print("yes" if data.get("data", {}).get("result") else "")' <<<"$queue_depth_metrics_result")
  if [ -n "$agent_metric_found" ] && [ -n "$core_metric_found" ] && [ -n "$queue_depth_metrics_found" ]; then
    break
  fi
  sleep 2
done
if [ -z "$agent_metric_found" ] || [ -z "$core_metric_found" ] || [ -z "$queue_depth_metrics_found" ]; then
  echo "timed out waiting for exported Core and Agents metrics" >&2
  exit 1
fi

# 可观测性故障不得影响业务：停止 Collector 后再跑一条完整评分链。
"${COMPOSE[@]}" stop otel-collector
offline_response=$(curl --silent --fail \
  -H 'Content-Type: application/json' \
  -d '{"title":"Collector Offline Topic","angle":"Business continues","summary":"Telemetry is optional","targetPlatforms":["zhihu"]}' \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/topics")
offline_topic_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$offline_response")
wait_sql "select status::text from topics where id = '$offline_topic_id'" scored

echo "E2E passed: M1 topic loop, three-platform M2 writing, article evaluation dispatch, tracing, and telemetry-outage isolation"
