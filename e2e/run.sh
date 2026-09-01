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

# 隔离 E2E 只验证显式触发的工作流；关闭测试实例的自动内容调度，避免
# 每分钟 tick 产生额外 run 抢占同一组 pgmq 队列并造成等待抖动。
${COMPOSE[@]} exec -T postgres psql -U scholar -d scholar -Atqc \
  "update scheduler_settings set settings = jsonb_set(settings, '{contentWorkflow,enabled}', 'false'::jsonb) where id = true"

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

publication_payload=$(python3 -c 'import json,sys; from datetime import datetime,timedelta,timezone; data=json.load(sys.stdin); article=data["article"]; published=(datetime.now(timezone.utc)-timedelta(days=8)).isoformat(); print(json.dumps({"platformPostId":"https://example.test/scholars-e2e-xhs","publishedAt":published,"finalTitle":article["title"]+"（人工终稿）","finalContentMd":article["contentMd"]+"\n\n人工补充：这是一处可追溯的小幅修改。","followerCountAtPublish":1234}, ensure_ascii=False))' <<<"$xhs_detail")
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

# M3 数据回流：同一平台同一窗口的三个样本必须得到确定性的 0/50/100 百分位，
# 标准窗口补录后提醒消失，随后进入 Reflector 周报和 evidence 非空的 insight。
publication_payload_2=$(python3 -c 'import json,sys; data=json.load(sys.stdin); data["platformPostId"]="https://example.test/scholars-e2e-xhs-2"; print(json.dumps(data, ensure_ascii=False))' <<<"$publication_payload")
publication_payload_3=$(python3 -c 'import json,sys; data=json.load(sys.stdin); data["platformPostId"]="https://example.test/scholars-e2e-xhs-3"; print(json.dumps(data, ensure_ascii=False))' <<<"$publication_payload")
publication_id_2=$(curl --silent --fail -X POST -H 'Content-Type: application/json' \
  -d "$publication_payload_2" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/articles/${xhs_article_id}/publications" | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
publication_id_3=$(curl --silent --fail -X POST -H 'Content-Type: application/json' \
  -d "$publication_payload_3" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/articles/${xhs_article_id}/publications" | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
captured_at=$(python3 -c 'from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(days=7)).isoformat())')
for spec in "$publication_id:100" "$publication_id_2:200" "$publication_id_3:300"; do
  metric_publication_id=${spec%%:*}
  metric_views=${spec##*:}
  metric_payload=$(python3 -c 'import json,sys; publication_id,views,captured=sys.argv[1:]; print(json.dumps({"snapshotWindow":"h24","capturedAt":captured,"metrics":{"views":int(views),"likes":int(views)//10,"favorites":int(views)//20,"comments":2,"shares":1,"follows":1}}))' "$metric_publication_id" "$metric_views" "$captured_at")
  curl --silent --fail -X POST -H 'Content-Type: application/json' \
    -d "$metric_payload" \
    "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/publications/${metric_publication_id}/metrics" >/dev/null
done
wait_sql "select string_agg(round(performance_percentile)::int::text, ',' order by performance_percentile) from metric_snapshots where publication_id in ('$publication_id','$publication_id_2','$publication_id_3') and snapshot_window='h24'" "0,50,100"

import_payload=$(python3 -c 'import json,sys; from datetime import datetime,timedelta,timezone; p2,p3=sys.argv[1:]; captured=(datetime.now(timezone.utc)-timedelta(days=5)).isoformat(); metrics={"views":400,"likes":40,"favorites":20,"comments":6,"shares":3,"follows":2}; print(json.dumps({"items":[{"publicationId":p2,"snapshotWindow":"h72","capturedAt":captured,"metrics":metrics},{"publicationId":p3,"snapshotWindow":"h72","capturedAt":captured,"metrics":metrics}]}))' "$publication_id_2" "$publication_id_3")
curl --silent --fail -X POST -H 'Content-Type: application/json' -d "$import_payload" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/metrics/import" >/dev/null
wait_sql "select count(*)::text from metric_snapshots where publication_id in ('$publication_id_2','$publication_id_3') and snapshot_window='h72' and source='import'" 2

before_atomic_count=$("${COMPOSE[@]}" exec -T postgres psql -U scholar -d scholar -Atc \
  "select count(*) from metric_snapshots where publication_id='$publication_id_3' and snapshot_window='custom'")
bad_import_payload=$(python3 -c 'import json,sys; from datetime import datetime,timezone; p1,p3=sys.argv[1:]; captured=datetime.now(timezone.utc).isoformat(); metrics={"views":999,"likes":1,"favorites":1,"comments":1,"shares":1,"follows":1}; print(json.dumps({"items":[{"publicationId":p1,"snapshotWindow":"h24","capturedAt":captured,"metrics":metrics},{"publicationId":p3,"snapshotWindow":"custom","capturedAt":captured,"metrics":metrics}]}))' "$publication_id" "$publication_id_3")
bad_import_status=$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -d "$bad_import_payload" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/metrics/import")
test "$bad_import_status" = 409
after_atomic_count=$("${COMPOSE[@]}" exec -T postgres psql -U scholar -d scholar -Atc \
  "select count(*) from metric_snapshots where publication_id='$publication_id_3' and snapshot_window='custom'")
test "$before_atomic_count" = "$after_atomic_count"

reminders=$(curl --silent --fail --get --data-urlencode 'remindersOnly=true' \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/publications")
python3 -c 'import json,sys; data=json.load(sys.stdin); target=next(item for item in data["items"] if item["publication"]["id"]==sys.argv[1]); assert {r["snapshotWindow"] for r in target["reminders"]}=={"h72","d7"}, target' "$publication_id" <<<"$reminders"

for window in h72 d7; do
  window_payload=$(python3 -c 'import json,sys; from datetime import datetime,timedelta,timezone; window=sys.argv[1]; days=5 if window=="h72" else 0; captured=(datetime.now(timezone.utc)-timedelta(days=days)).isoformat(); print(json.dumps({"snapshotWindow":window,"capturedAt":captured,"metrics":{"views":500,"likes":50,"favorites":30,"comments":8,"shares":4,"follows":2}}))' "$window")
  curl --silent --fail -X POST -H 'Content-Type: application/json' \
    -d "$window_payload" \
    "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/publications/${publication_id}/metrics" >/dev/null
done
publication_metrics=$(curl --silent --fail \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/publications/${publication_id}/metrics")
test "$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"$publication_metrics")" = 3

reflect_period=$(python3 -c 'import json; from datetime import datetime,timedelta,timezone; end=datetime.now(timezone.utc); print(json.dumps({"periodStart":(end-timedelta(days=10)).isoformat(),"periodEnd":end.isoformat()}))')
curl --silent --fail -X POST -H 'Content-Type: application/json' -d "$reflect_period" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/reflections/run" >/dev/null
wait_sql "select count(*)::text from weekly_reports" 1
wait_sql "select count(*)::text from insights where jsonb_array_length(evidence) > 0" 2
wait_sql "select count(*)::text from pgmq.q_memory_reflect" 0
weekly_report=$(curl --silent --fail "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/reports/weekly")
python3 -c 'import json,sys; data=json.load(sys.stdin); assert len(data)==1; report=data[0]; assert report["sampleCount"]>=3; assert report["calibration"]["coldStart"] is True; assert report["calibration"]["correlations"]' <<<"$weekly_report"
insight_response=$(curl --silent --fail "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/insights")
insight_ids=$(python3 -c 'import json,sys; data=json.load(sys.stdin); assert len(data)==2 and all(item["evidence"] for item in data); print(" ".join(item["id"] for item in data))' <<<"$insight_response")
for insight_id in $insight_ids; do
  curl --silent --fail -X PATCH -H 'Content-Type: application/json' -d '{"status":"active"}' \
    "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/insights/${insight_id}" >/dev/null
done
wait_sql "select count(*)::text from insights where status='active' and manual_status_override" 2

# SPEC-010 内容生产工作流：完整六阶段、动态漏斗、快照血缘与节点 replay。
workflow_source_id=$(${COMPOSE[@]} exec -T postgres psql -U scholar -d scholar -Atqc \
  "insert into sources (name,type,url,category,weight,enabled,fetch_config) values ('SPEC-010 E2E Feed','rss','http://fake-ai:8081/rss','research',1.0,true,'{\"role\":\"material\",\"fullText\":\"rss_description\",\"maxItems\":10}') returning id")
workflow_response=$(curl --silent --fail -X POST -H 'Content-Type: application/json' \
  -d "{\"sourceIds\":[\"$workflow_source_id\"],\"metadata\":{\"e2e\":\"spec010\"}}" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs")
workflow_run_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$workflow_response")
test -n "$workflow_run_id"
wait_sql "select status::text from workflow_runs where id='$workflow_run_id'" waiting_human_review
wait_sql "select count(*)::text from workflow_node_runs where run_id='$workflow_run_id'" 6
wait_sql "select count(*)::text from workflow_node_runs where run_id='$workflow_run_id' and output_snapshot_id is not null" 6
wait_sql "select count(*)::text from workflow_events where run_id='$workflow_run_id' and node_key='source_fetch' and status='succeeded'" 1
wait_sql "select count(*)::text from workflow_events where run_id='$workflow_run_id' and node_key='topic_scout' and status='succeeded'" 1
wait_sql "select count(*)::text from workflow_item_decisions where run_id='$workflow_run_id' and item_type='topic'" 1
wait_sql "select count(*)::text from workflow_item_decisions where run_id='$workflow_run_id' and item_type='article'" 1
wait_sql "select count(*)::text from workflow_artifacts where run_id='$workflow_run_id' and node_key='human_review'" 1

workflow_detail=$(curl --silent --fail \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs/${workflow_run_id}")
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["inputSnapshotId"]; assert len(d["nodeRuns"])==6; assert all(n["outputSnapshotId"] for n in d["nodeRuns"]); assert d["decisions"]' <<<"$workflow_detail"
config_snapshot_id=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["configSnapshotId"])' <<<"$workflow_detail")
config_snapshot=$(curl --silent --fail \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs/${workflow_run_id}/snapshots/${config_snapshot_id}")
python3 -c 'import json,sys; d=json.load(sys.stdin); p=d["payload"]; assert p["schemaVersion"]==1; assert p["configVersion"]; assert p["resolution"]["status"]=="validated"; assert p["effective"]["topicPassThreshold"] >= 0' <<<"$config_snapshot"
workflow_list=$(curl --silent --fail \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs?limit=10")
python3 -c 'import json,sys; d=json.load(sys.stdin); run=next(item for item in d["items"] if item["id"]==sys.argv[1]); assert "funnel" in run["summary"]; assert set(run["summary"]["funnel"]) >= {"source_fetch","topic_scout","topic_evaluate","article_write","article_evaluate","human_review"}; assert "total" in run["summary"]; assert run["summary"]["total"]["artifactCount"] >= 1' "$workflow_run_id" <<<"$workflow_list"

# 快照 API 必须返回所属运行的不可变 payload，并携带与数据库一致的 SHA-256。
workflow_snapshot_id=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(n["outputSnapshotId"] for n in d["nodeRuns"] if n["nodeKey"]=="source_fetch"))' <<<"$workflow_detail")
workflow_snapshot_sha=$(${COMPOSE[@]} exec -T postgres psql -U scholar -d scholar -Atc \
  "select sha256 from workflow_snapshots where id='$workflow_snapshot_id' and run_id='$workflow_run_id'")
workflow_snapshot=$(curl --silent --fail \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs/${workflow_run_id}/snapshots/${workflow_snapshot_id}")
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["runId"]==sys.argv[1]; assert d["id"]==sys.argv[2]; assert d["sha256"]==sys.argv[3]; assert d["payload"]' \
  "$workflow_run_id" "$workflow_snapshot_id" "$workflow_snapshot_sha" <<<"$workflow_snapshot"

# 空 selected_items 必须被拒绝，确认 replay 范围校验在 API 层生效。
invalid_replay_status=$(curl --silent --output /dev/null --write-out '%{http_code}' -X POST \
  -H 'Content-Type: application/json' \
  -d '{"replayFromNode":"article_write","replayScope":{"mode":"selected_items","itemIds":[]}}' \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs/${workflow_run_id}/replay")
test "$invalid_replay_status" = 400

# 从 article_write replay：只使用父运行的 topic 输出，不重新采集 RSS 或生成 topic。
topic_id=$(${COMPOSE[@]} exec -T postgres psql -U scholar -d scholar -Atc \
  "select item_id from workflow_item_decisions where run_id='$workflow_run_id' and item_type='topic' and decision='accepted' limit 1")
parent_article_id=$(${COMPOSE[@]} exec -T postgres psql -U scholar -d scholar -Atc \
  "select artifact_id from workflow_artifacts where run_id='$workflow_run_id' and node_key='human_review' limit 1")
write_replay=$(curl --silent --fail -X POST -H 'Content-Type: application/json' \
  -d "{\"replayFromNode\":\"article_write\",\"replayScope\":{\"mode\":\"selected_items\",\"itemIds\":[\"$topic_id\"]}}" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs/${workflow_run_id}/replay")
write_replay_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$write_replay")
wait_sql "select parent_run_id::text from workflow_runs where id='$write_replay_id'" "$workflow_run_id"
write_replay_detail=$(curl --silent --fail "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs/${write_replay_id}")
write_replay_config_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["configSnapshotId"])' <<<"$write_replay_detail")
write_replay_config=$(curl --silent --fail "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs/${write_replay_id}/snapshots/${write_replay_config_id}")
python3 -c 'import json,sys; p=json.load(sys.stdin)["payload"]; assert p["schemaVersion"]==1; assert p["effective"]["topicPassThreshold"] == 60.0' <<<"$write_replay_config"
wait_sql "select status::text from workflow_runs where id='$write_replay_id'" waiting_human_review
wait_sql "select count(*)::text from raw_items where correlation_id='$write_replay_id'" 0
wait_sql "select count(*)::text from workflow_node_runs where run_id='$write_replay_id' and node_key in ('source_fetch','topic_scout','topic_evaluate') and status='skipped'" 3
write_replay_article_id=$(${COMPOSE[@]} exec -T postgres psql -U scholar -d scholar -Atc \
  "select artifact_id from workflow_artifacts where run_id='$write_replay_id' and node_key='human_review' limit 1")
test -n "$write_replay_article_id"
test "$write_replay_article_id" != "$parent_article_id"
wait_sql "select count(*)::text from articles where id='$write_replay_article_id' and topic_id='$topic_id' and version > 1" 1

# article_evaluate evaluate_only：复用已有文章，仅重评估，所有下游节点必须 skipped。
article_id="$parent_article_id"
eval_replay=$(curl --silent --fail -X POST -H 'Content-Type: application/json' \
  -d "{\"replayFromNode\":\"article_evaluate\",\"replayScope\":{\"mode\":\"evaluate_only\",\"itemIds\":[\"$article_id\"]},\"configOverrides\":{\"articlePassThreshold\":0}}" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs/${workflow_run_id}/replay")
eval_replay_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$eval_replay")
wait_sql "select status::text from workflow_runs where id='$eval_replay_id'" completed
wait_sql "select count(*)::text from workflow_node_runs where run_id='$eval_replay_id' and node_key='human_review' and status='skipped'" 1
wait_sql "select count(*)::text from workflow_item_decisions where run_id='$eval_replay_id' and item_type='article'" 1

# 快照必须按 run_id 隔离，父运行的 snapshot 不能通过 replay 运行读取。
cross_run_snapshot_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs/${eval_replay_id}/snapshots/${workflow_snapshot_id}")
test "$cross_run_snapshot_status" = 404

# 相同 replay 请求必须幂等返回同一个子运行，不能重复投递业务任务。
eval_replay_again=$(curl --silent --fail -X POST -H 'Content-Type: application/json' \
  -d "{\"replayFromNode\":\"article_evaluate\",\"replayScope\":{\"mode\":\"evaluate_only\",\"itemIds\":[\"$article_id\"]},\"configOverrides\":{\"articlePassThreshold\":0}}" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs/${workflow_run_id}/replay")
eval_replay_again_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$eval_replay_again")
test "$eval_replay_again_id" = "$eval_replay_id"

# 写入可控的 usage 样本，确保 compare 暴露阶段和运行级 token/cost 指标。
${COMPOSE[@]} exec -T postgres psql -U scholar -d scholar -Atqc \
  "insert into agent_runs (job_type, status, correlation_id, tokens_in, tokens_out, cost_usd) values ('article.evaluate','succeeded','$workflow_run_id',100,50,0.12),('article.evaluate','succeeded','$eval_replay_id',140,70,0.18)"

compare_response=$(curl --silent --fail -X POST -H 'Content-Type: application/json' \
  -d "{\"otherRunId\":\"$eval_replay_id\"}" \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/workflow/runs/${workflow_run_id}/compare")
python3 -c 'import json,sys; d=json.load(sys.stdin); s=d["stages"]["article_evaluate"]; assert d["sameInput"]; assert s["base"]["inputCount"] >= 1; assert s["base"]["tokenCount"] >= 150; assert s["other"]["tokenCount"] >= 210; assert s["base"]["cost"] == 0.12; assert s["other"]["cost"] == 0.18; assert d["cost"]["base"]["tokenCount"] >= 150; assert d["cost"]["other"]["tokenCount"] >= 210; assert d["cost"]["base"]["durationSeconds"] >= 0; assert d["cost"]["other"]["durationSeconds"] >= 0; assert "artifacts" in d' <<<"$compare_response"

curl --silent --fail \
  -H 'Content-Type: application/json' \
  -d '{"url":"http://fake-ai:8081/article","note":"cross-repository e2e"}' \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/ingest/url" >/dev/null
wait_sql "select case when exists (select 1 from topics t join raw_items r on r.id = any(t.raw_item_ids) where r.url = 'http://fake-ai:8081/article' and t.status in ('scored', 'written') order by t.created_at desc limit 1) then 'ready' else '' end" ready
memory_topic_id=$("${COMPOSE[@]}" exec -T postgres psql -U scholar -d scholar -Atc \
  "select t.id from topics t join raw_items r on r.id = any(t.raw_item_ids) where r.url='http://fake-ai:8081/article' order by t.created_at desc limit 1")
wait_sql "select title from topics where id='$memory_topic_id'" "Memory-Aware Deterministic E2E Topic"
memory_topic_status=$(${COMPOSE[@]} exec -T postgres psql -U scholar -d scholar -Atc \
  "select status::text from topics where id='$memory_topic_id'")
if [ "$memory_topic_status" = "scored" ]; then
  curl --silent --fail -X POST \
    "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/topics/${memory_topic_id}/approve" >/dev/null
fi
wait_sql "select status::text from topics where id='$memory_topic_id'" written
wait_sql "select case when count(*) > 0 then 'ready' else 'empty' end from articles where topic_id='$memory_topic_id' and title like '记忆注入：%'" ready

retired_insight_id=${insight_ids%% *}
curl --silent --fail -X PATCH -H 'Content-Type: application/json' -d '{"status":"retired"}' \
  "http://127.0.0.1:${CORE_HOST_PORT}/api/v1/insights/${retired_insight_id}" >/dev/null
wait_sql "select count(*)::text from insights where id='$retired_insight_id' and status='retired' and manual_status_override" 1

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

echo "E2E passed: M1 topic loop; M2 writing/review/publication; M3 metrics, percentiles, reminders, Reflector, reports and insight governance; tracing and telemetry-outage isolation"
