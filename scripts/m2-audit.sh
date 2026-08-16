#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${POSTGRES_CONTAINER:-scholars-prod-postgres-1}
BUSINESS_DB=${BUSINESS_DB:-scholar}
PROMETHEUS_URL=${PROMETHEUS_URL:-http://127.0.0.1:9090}

db() {
    docker exec "$CONTAINER" psql -U scholar -d "$BUSINESS_DB" "$@"
}

echo "audit_time=$(TZ=Asia/Shanghai date '+%Y-%m-%dT%H:%M:%S%z')"
echo "--- M2 topics and three-platform completion ---"
db -P pager=off -c "with per_topic as (
  select t.id, t.title, t.updated_at,
         count(distinct a.platform) filter (where a.status in ('pending_review','approved','published','rejected')) as completed_platforms,
         count(*) filter (where a.version > 1) as rewrites,
         max(a.version) as max_version
  from topics t left join articles a on a.topic_id = t.id
  where t.status in ('in_writing','written')
  group by t.id
) select * from per_topic order by updated_at desc limit 30"

echo "--- ArticleJudge completeness and deterministic decisions ---"
db -P pager=off -c "select
  count(*) as evaluations,
  count(*) filter (where dimension_scores <> '{}'::jsonb and dimension_reasons <> '{}'::jsonb) as with_dimension_evidence,
  count(*) filter (where passed = (total_score >= pass_threshold and vetoed_dimension is null)) as deterministic_match,
  count(distinct rubric_version) as rubric_versions
from article_evaluations"

echo "--- immutable rewrite invariants ---"
db -P pager=off -c "select
  count(*) filter (where version > 3) as versions_above_limit,
  count(*) filter (where version > 1 and previous_article_id is null) as broken_predecessors,
  count(*) filter (where status = 'rewrite_queued') as archived_rewrite_versions
from articles"

echo "--- human review and publication edit ratio ---"
db -P pager=off -c "select
  count(*) filter (where status = 'pending_review') as waiting_review,
  count(*) filter (where status = 'approved') as approved_not_published,
  count(*) filter (where status = 'published') as published_articles,
  count(*) filter (where status = 'rejected') as rejected_articles
from articles"
db -P pager=off -c "select
  count(*) as publications,
  count(*) filter (where edit_ratio is not null) as measured,
  round(avg(edit_ratio) filter (where edit_ratio is not null), 4) as average_edit_ratio,
  count(*) filter (where edit_ratio < 0.30) as below_m2_target
from publications"

echo "--- Formatter violation metric ---"
if curl --silent --fail --get \
    --data-urlencode 'query=sum(scholar_agent_formatter_violations_total)' \
    "$PROMETHEUS_URL/api/v1/query"; then
    echo
else
    echo "Prometheus is not reachable at $PROMETHEUS_URL; set PROMETHEUS_URL to audit Formatter violations." >&2
fi
