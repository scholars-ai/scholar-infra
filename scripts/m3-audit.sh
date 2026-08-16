#!/usr/bin/env bash
set -euo pipefail

CONTAINER=${POSTGRES_CONTAINER:-scholars-prod-postgres-1}
BUSINESS_DB=${BUSINESS_DB:-scholar}

db() {
    docker exec "$CONTAINER" psql -U scholar -d "$BUSINESS_DB" "$@"
}

echo "audit_time=$(TZ=Asia/Shanghai date '+%Y-%m-%dT%H:%M:%S%z')"
echo "--- Metric snapshot coverage and overdue windows ---"
db -P pager=off -c "with windows(name, delay) as (
  values ('h24'::metric_window, interval '24 hours'),
         ('h72'::metric_window, interval '72 hours'),
         ('d7'::metric_window, interval '7 days')
) select p.platform,
  count(distinct p.id) as publications,
  count(ms.id) as snapshots,
  count(*) filter (where now() >= p.published_at + w.delay and ms.id is null) as overdue_windows
from publications p cross join windows w
left join metric_snapshots ms on ms.publication_id=p.id and ms.snapshot_window=w.name
group by p.platform order by p.platform"

echo "--- Performance percentile isolation and weight versions ---"
db -P pager=off -c "select p.platform, ms.snapshot_window,
  count(*) as samples,
  min(ms.performance_percentile) as min_percentile,
  max(ms.performance_percentile) as max_percentile,
  count(distinct ms.performance_weight_version) as weight_versions
from metric_snapshots ms join publications p on p.id=ms.publication_id
where ms.snapshot_window <> 'custom'
group by p.platform, ms.snapshot_window
order by p.platform, ms.snapshot_window"

echo "--- Reflector reports and evidence discipline ---"
db -P pager=off -c "select id, period_start, period_end, sample_count,
  calibration->>'coldStart' as cold_start, created_at
from weekly_reports order by period_end desc limit 12"
db -P pager=off -c "select status, count(*) as insights,
  count(*) filter (where jsonb_typeof(evidence)='array' and jsonb_array_length(evidence)>0) as with_evidence,
  round(avg(confidence), 3) as average_confidence
from insights group by status order by status"

echo "--- Queue and failed jobs ---"
db -P pager=off -c "select
  (select count(*) from pgmq.q_memory_reflect) as memory_reflect_queue,
  (select count(*) from job_failures where queue='memory_reflect' and not archived) as unarchived_failures"
