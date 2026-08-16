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
wait_sql "select count(*)::text from articles where topic_id = '$manual_topic_id'" 4
wait_sql "select count(distinct platform)::text from articles where topic_id = '$manual_topic_id'" 3
wait_sql "select count(*)::text from article_evaluations e join articles a on a.id = e.article_id where a.topic_id = '$manual_topic_id'" 4
wait_sql "select count(*)::text from articles where topic_id = '$manual_topic_id' and status = 'pending_review'" 3
wait_sql "select count(*)::text from articles where topic_id = '$manual_topic_id' and platform = 'xiaohongshu' and version = 1 and status = 'rewrite_queued'" 1
wait_sql "select count(*)::text from articles newer join articles older on newer.previous_article_id = older.id where newer.topic_id = '$manual_topic_id' and newer.platform = 'xiaohongshu' and newer.version = 2 and older.version = 1" 1
wait_sql "select count(*)::text from schedule_runs where schedule_key like 'article_evaluate:%' and msg_id is not null" 4
wait_sql "select count(*)::text from schedule_runs where schedule_key like 'article_write:%:rewrite:2' and msg_id is not null" 1
wait_sql "select count(*)::text from pgmq.q_article_evaluate" 0
wait_sql "select count(*)::text from articles where topic_id = '$manual_topic_id' and version > 3" 0
wait_sql "select count(*)::text from (select distinct on (platform) id from articles where topic_id = '$manual_topic_id' order by platform, version desc) latest join lateral (select passed from article_evaluations where article_id = latest.id order by created_at desc limit 1) e on e.passed" 3
wait_sql "select count(*)::text from state_transition_events where entity_type = 'article' and entity_id in (select id from articles where topic_id = '$manual_topic_id') and (from_status, to_status) in (('draft','scored'),('scored','rewrite_queued'),('scored','pending_review'))" 8
wait_sql "select count(*)::text from (select min(created_at) filter (where entity_type = 'topic' and entity_id = '$manual_topic_id' and to_status = 'approved') as approved_at, max(created_at) filter (where entity_type = 'article' and entity_id in (select id from articles where topic_id = '$manual_topic_id') and to_status = 'pending_review') as completed_at from state_transition_events) timing where completed_at - approved_at <= interval '10 minutes'" 1

# M2 人工终审 API：列表/详情/评分历史与两种终审决策都必须走 Core 状态机。
article_list=$(curl --silent --fail --get \
  --data-urlencode 'status=pending_review' \
  --data-urlencode "topicId=$manual_topic_id" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/articles")
test "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])' <<<"$article_list")" = 3
xhs_article_id=$("${COMPOSE[@]}" exec -T postgres psql -U scholar -d scholar -Atc \
  "select id from articles where topic_id = '$manual_topic_id' and platform = 'xiaohongshu' order by version desc limit 1")
zhihu_article_id=$("${COMPOSE[@]}" exec -T postgres psql -U scholar -d scholar -Atc \
  "select id from articles where topic_id = '$manual_topic_id' and platform = 'zhihu' order by version desc limit 1")
wechat_article_id=$("${COMPOSE[@]}" exec -T postgres psql -U scholar -d scholar -Atc \
  "select id from articles where topic_id = '$manual_topic_id' and platform = 'wechat' order by version desc limit 1")

xhs_detail=$(curl --silent --fail "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/articles/${xhs_article_id}")
test "$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(len(data["versions"]))' <<<"$xhs_detail")" = 2
test "$(curl --silent --fail "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/articles/${xhs_article_id}/evaluations" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 1

curl --silent --fail -X POST "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/articles/${xhs_article_id}/approve" >/dev/null
curl --silent --fail -X POST "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/articles/${zhihu_article_id}/approve" >/dev/null
curl --silent --fail -X POST -H 'Content-Type: application/json' \
  -d '{"reason":"E2E manual rejection"}' \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/articles/${wechat_article_id}/reject" >/dev/null
wait_sql "select count(*)::text from articles where id in ('$xhs_article_id','$zhihu_article_id') and status = 'approved'" 2
wait_sql "select status::text from articles where id = '$wechat_article_id'" rejected

publication_payload=$(python3 -c 'import json,sys; data=json.load(sys.stdin); article=data["article"]; print(json.dumps({"platformPostId":"https://example.test/scholars-e2e-xhs","finalTitle":article["title"]+"（人工终稿）","finalContentMd":article["contentMd"]+"\n\n人工补充：这是一处可追溯的小幅修改。","followerCountAtPublish":1234}, ensure_ascii=False))' <<<"$xhs_detail")
publication_response=$(curl --silent --fail -X POST -H 'Content-Type: application/json' \
  -d "$publication_payload" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/articles/${xhs_article_id}/publications")
publication_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$publication_response")
test -n "$publication_id"
python3 -c 'import json,sys; ratio=json.load(sys.stdin)["editRatio"]; assert 0 < ratio < 1, ratio' <<<"$publication_response"
wait_sql "select status::text from articles where id = '$xhs_article_id'" published
wait_sql "select count(*)::text from publications where id = '$publication_id' and article_id = '$xhs_article_id' and final_content_diff like '%scholars-final-diff/v1%' and edit_ratio > 0 and edit_ratio < 1" 1
wait_sql "select count(*)::text from state_transition_events where entity_type = 'article' and entity_id = '$xhs_article_id' and from_status = 'approved' and to_status = 'published' and metadata->>'publicationId' = '$publication_id'" 1

duplicate_status=$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$publication_payload" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/articles/${xhs_article_id}/publications")
test "$duplicate_status" = 409

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

echo "E2E passed: M1 topic loop; M2 writing, judging, immutable rewrite, human review, publication diff/edit ratio; tracing and telemetry-outage isolation"
