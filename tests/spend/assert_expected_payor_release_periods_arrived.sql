/*
  Blocking source-period gate. Expected PAYOR_A MMR periods must be present by
  their in-content payment month. Certified-unavailable and optional periods
  are intentionally excluded; no rows are fabricated for those exceptions.

  Passes = zero rows.
*/

{{ config(severity='error', tags=['payor', 'spend', 'raf', 'freshness']) }}

with expected as (
    select payor, report_type, cast(source_period as string) as source_period
    from {{ ref('payor_expected_release_calendar') }}
    where expectation_status = 'expected'
),

arrived as (
    select distinct
        'PAYOR_A' as payor,
        'MMR' as report_type,
        substr(trim(payment_date), 1, 6) as source_period
    from {{ ref('stg_payor__payor_alpha_mmr') }}
    where substr(trim(payment_date), 1, 6) rlike '^[0-9]{6}$'
)

select
    e.payor,
    e.report_type,
    e.source_period,
    'EXPECTED_RELEASE_NOT_ARRIVED' as failure_reason
from expected e
left join arrived a
    on e.payor = a.payor
    and e.report_type = a.report_type
    and e.source_period = a.source_period
where a.source_period is null
