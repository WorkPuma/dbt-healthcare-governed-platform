{{
    config(
        severity='error',
        tags=['marts_bi_v3', 'registry', 'metric_views', 'data_quality']
    )
}}

/*
  Metric-view generation contract.

  Every metric_definitions row is projected into a Unity Catalog metric view
  measure by macros/v3_generate_metric_views.sql + scripts/metric_views/
  generate_metric_views.py. This test fails the build if any row could not be
  turned into a correct measure — which would either crash generation
  (unsupported agg) or, worse, silently emit a wrong number. It is the parity
  backstop that keeps the Databricks AI/BI path faithful to marts_bi_v3.metric().

  A row is NON-generatable when:
    1. source_mart is blank — the generator keys a view off schema.mart, so a
       blank source_mart would silently drop the metric from both the DDL and
       the grounding catalog (the generator now hard-errors on this), OR
    2. agg is not one of the eight supported aggregations, OR
    3. a simple aggregation (count_distinct / sum / avg / latest) has no
       sum_column, OR
    4. a rate aggregation (rate / rate_distinct / rate_latest) is missing its
       numerator or denominator column.

  (`count` is allowed to omit sum_column — it maps to COUNT(1).)

  Note on latest / rate_latest + date_column: a date_column is NOT required.
  When present (e.g. period_start on mart_membership_kpis_monthly) the
  generator adds a `semiadditive: last` window so the measure resolves the most
  recent period. When absent (a timeless snapshot mart such as mart_patients)
  the generator emits a plain aggregate, which is the correct current-state
  value and matches marts_bi_v3.metric() behavior for a timeless mart — so this
  is intentionally NOT a violation.
*/

with defs as (
    select
        name,
        nullif(trim(coalesce(source_mart, '')), '') as source_mart,
        lower(coalesce(agg, '')) as agg,
        nullif(trim(coalesce(sum_column, '')), '') as sum_column,
        nullif(trim(coalesce(rate_num, '')), '')   as rate_num,
        nullif(trim(coalesce(rate_denom, '')), '') as rate_denom
    from {{ ref('metric_definitions') }}
),

violations as (
    select name, source_mart, agg, 'missing_source_mart' as reason
    from defs
    where source_mart is null

    union all

    select name, source_mart, agg, 'unsupported_agg' as reason
    from defs
    where agg not in (
        'count', 'count_distinct', 'sum', 'avg',
        'latest', 'rate', 'rate_distinct', 'rate_latest'
    )

    union all

    select name, source_mart, agg, 'missing_sum_column' as reason
    from defs
    where agg in ('count_distinct', 'sum', 'avg', 'latest')
      and sum_column is null

    union all

    select name, source_mart, agg, 'missing_rate_columns' as reason
    from defs
    where agg in ('rate', 'rate_distinct', 'rate_latest')
      and (rate_num is null or rate_denom is null)
)

select *
from violations
