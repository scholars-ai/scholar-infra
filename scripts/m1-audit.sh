#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${POSTGRES_CONTAINER:-scholars-prod-postgres-1}
BUSINESS_DB=${BUSINESS_DB:-scholar}
LANGFUSE_DB=${LANGFUSE_DB:-langfuse}
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

db() {
    docker exec "$CONTAINER" psql -U scholar -d "$BUSINESS_DB" "$@"
}

langfuse() {
    docker exec "$CONTAINER" psql -U scholar -d "$LANGFUSE_DB" "$@"
}

db -At -c "select distinct on (te.topic_id) ar.langfuse_trace_id from topic_evaluations te join agent_runs ar on ar.id = te.agent_run_id where ar.job_type = 'topic.evaluate' and ar.status = 'succeeded' and ar.langfuse_trace_id is not null order by te.topic_id, te.created_at desc" | sort -u >"$TMP_DIR/latest-traces"
langfuse -At -c "select distinct trace_id from observations where type = 'GENERATION' and trace_id is not null" | sort -u >"$TMP_DIR/generation-traces"
langfuse -At -c "select distinct trace_id from scores where name = 'topic_total_score'" | sort -u >"$TMP_DIR/score-traces"

echo "audit_time=$(TZ=Asia/Shanghai date '+%Y-%m-%dT%H:%M:%S%z')"
echo "--- topics by Beijing day ---"
db -P pager=off -c "select (created_at at time zone 'Asia/Shanghai')::date as day, count(*) as topics, count(*) filter (where status in ('scored', 'rejected')) as judged from topics group by 1 order by 1 desc"
echo "--- semantic duplicates ---"
db -P pager=off -c "with pairs as (select 1 - (a.embedding <=> b.embedding) as similarity from topics a join topics b on a.id < b.id where a.embedding is not null and b.embedding is not null) select count(*) as pairs, count(*) filter (where similarity >= 0.92) as duplicate_pairs, round(coalesce(max(similarity), 0)::numeric, 6) as max_similarity from pairs"
echo "--- queues ---"
for queue in source_fetch topic_scout topic_evaluate; do
    db -P pager=off -c "select queue_name, queue_length, queue_visible_length, total_messages from pgmq.metrics('$queue')"
done
echo "--- business and Langfuse totals ---"
db -P pager=off -c "select count(*) as evaluations, count(*) filter (where ar.status = 'succeeded') as succeeded, count(*) filter (where ar.tokens_in is not null and ar.tokens_out is not null) as tokenized from topic_evaluations te join agent_runs ar on ar.id = te.agent_run_id"
langfuse -P pager=off -c "select count(*) filter (where type = 'GENERATION') as generations from observations" -c "select count(*) filter (where name = 'topic_total_score') as topic_scores from scores"
echo "--- latest evaluation trace parity ---"
printf 'latest_evaluations=%s\n' "$(wc -l <"$TMP_DIR/latest-traces")"
printf 'missing_generation=%s\n' "$(comm -23 "$TMP_DIR/latest-traces" "$TMP_DIR/generation-traces" | wc -l)"
printf 'missing_topic_score=%s\n' "$(comm -23 "$TMP_DIR/latest-traces" "$TMP_DIR/score-traces" | wc -l)"
