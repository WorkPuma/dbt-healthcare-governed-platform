/*
  PAYOR_B cumulative claims: the latest valid medical + Part B Rx staging releases
  must conserve both paid line count and plan-paid dollars through claims
  detail, rollup, and the patient-month fact. Grain-changing layers compare
  dollars only.

  claims_detail intentionally unions medical (stg_payor__uhc_claims) with
  Part B Rx (stg_payor__uhc_rx); Part B alone is covered by
  assert_uhc_part_b_rx_accounting. Control total must include both.

  Passes = zero rows.
*/

{{ config(severity='error', tags=['spend', 'PAYOR_B', 'reconciliation']) }}

with latest_medical as (
    select max(release_date) as release_date
    from {{ ref('stg_payor__uhc_claims') }}
),

latest_rx as (
    select max(release_date) as release_date
    from {{ ref('stg_payor__uhc_rx') }}
),

medical_latest as (
    select
        count(*) as line_count,
        sum(plan_paid_amount) as paid_amount
    from {{ ref('stg_payor__uhc_claims') }}
    where release_date = (select release_date from latest_medical)
      and service_date_first is not null
      and plan_paid_amount is not null
),

part_b_rx_latest as (
    select
        count(*) as line_count,
        sum(plan_paid_amount) as paid_amount
    from {{ ref('stg_payor__uhc_rx') }}
    where release_date = (select release_date from latest_rx)
      and part_b_or_d = 'B'
      and fill_date is not null
      and plan_paid_amount is not null
),

control_totals as (
    select
        'staging_latest' as layer,
        m.line_count + r.line_count as line_count,
        coalesce(m.paid_amount, 0) + coalesce(r.paid_amount, 0) as paid_amount
    from medical_latest m
    cross join part_b_rx_latest r

    union all

    select 'claims_detail', count(*), sum(plan_paid_amount)
    from {{ ref('int_spend__claims_detail') }}
    where payor = 'PAYOR_B'

    union all

    select 'claims_rollup', cast(null as bigint), sum(total_cost)
    from {{ ref('int_spend__claims_rollup') }}
    where payor = 'PAYOR_B'

    union all

    select 'patient_month_fact', cast(null as bigint), sum(total_cost)
    from {{ ref('fct_spend__patient_month') }}
    where payor = 'PAYOR_B'
),

expected as (
    select line_count, paid_amount
    from control_totals
    where layer = 'staging_latest'
)

select
    c.layer,
    e.line_count as expected_line_count,
    c.line_count as actual_line_count,
    e.paid_amount as expected_paid_amount,
    c.paid_amount as actual_paid_amount,
    c.paid_amount - e.paid_amount as paid_amount_difference
from control_totals c
cross join expected e
where c.layer <> 'staging_latest'
  and (
      (c.layer = 'claims_detail' and c.line_count <> e.line_count)
      or abs(coalesce(c.paid_amount, 0) - coalesce(e.paid_amount, 0)) > 0.01
  )
