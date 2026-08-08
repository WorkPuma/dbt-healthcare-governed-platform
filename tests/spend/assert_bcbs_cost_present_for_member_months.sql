/*
  Guard: a mature PAYOR_A service month with paid member-months must carry paid cost.

  PAYOR_A ships ROLLING 12-MONTH claim files. The cost layer keys the authoritative
  view PER incurred service month (int_payor__payor_alpha_claims_normalized.is_latest_release),
  so a matured month that has rolled out of the newest file is still picked up
  from the last release that carried it. The prior behavior pinned every month to
  one global latest release, which silently zeroed the cost of any month older
  than that file's ~12-month window (e.g. Jan/Feb 2025 read $0 cost against live
  revenue and member-months). This test fails if that regression returns.

  Scope:
    * PAYOR_A only (PAYOR_B cost comes from a separate cumulative feed).
    * service_month from 2025-01 (dashboard inception) forward.
    * At least 3 months old, so paid claims have certainly landed -- this avoids
      flagging the bleeding-edge immature months, which legitimately can be near
      zero before claims run out.
    * Only months the PAYOR_A rolling-claim source actually covers (service_month <=
      max(incurred_month) in int_payor__payor_alpha_claims_normalized). A month beyond the
      latest incurred_month has simply not been received yet -- rolling-file lag, not
      a dropped snapshot -- so flagging it would be a false positive at the bleeding
      edge of the rolling file.

  A flagged month has member_months > 0 (revenue/eligibility present) but
  total_cost = 0, which for an aged PAYOR_A month that the claims source covers can
  only mean its claims snapshot was dropped, not that no care was delivered.

  Severity: error. Returns offending months (0 = pass).
*/

{{ config(severity='error', tags=['spend', 'PAYOR_A', 'cost', 'restatement']) }}

with payor_alpha_coverage as (
    -- Latest incurred service month present in the PAYOR_A rolling-claim source.
    -- Months beyond this point have no claims received yet (rolling-file lag), so
    -- they are excluded from scope to avoid false positives at the bleeding edge.
    select max(incurred_month) as latest_incurred_month
    from {{ ref('int_payor__payor_alpha_claims_normalized') }}
    where lower(payor) = 'PAYOR_A'
),

monthly as (
    select
        service_month,
        sum(coalesce(member_months, 0)) as member_months,
        sum(coalesce(total_cost, 0))    as total_cost
    from {{ ref('fct_spend__patient_month') }}
    where payor = 'PAYOR_A'
      and service_month >= date '2025-01-01'
      -- only months old enough that paid claims must have arrived
      and service_month < date_trunc('month', add_months(current_date(), -3))
      -- only months the PAYOR_A claims source actually covers; a month beyond the latest
      -- incurred_month has not been received yet (rolling-file lag), not a dropped
      -- snapshot, so flagging it would be a false positive.
      and service_month <= (select latest_incurred_month from payor_alpha_coverage)
    group by service_month
),

scope_check as (
    select count(*) as mature_month_count from monthly
)

-- Fail loudly if upstream data disappears and this test would otherwise pass vacuously.
select
    cast(null as date) as service_month,
    cast(null as double) as member_months,
    cast(null as double) as total_cost,
    'PAYOR_A cost regression test found zero mature service months in scope — upstream fct_spend__patient_month may be empty or filtered away.' as failure_message
from scope_check
where mature_month_count = 0

union all

select
    service_month,
    member_months,
    total_cost,
    concat('PAYOR_A service month ', cast(service_month as string),
           ' has ', cast(member_months as string),
           ' paid member-months but $0 paid cost -- a rolled-out claims snapshot, '
           'not absence of care (per-month restatement regression).') as failure_message
from monthly
where member_months > 0
  and total_cost = 0
