/*
  The latest cumulative PAYOR_B Rx snapshot contributes all Part B transactions.
  Part D remains excluded, and a strong four-key medical overlap blocks the build
  for investigation rather than silently dropping an ambiguous pharmacy row.

  Passes = zero rows.
*/

{{ config(severity='error', tags=['spend', 'PAYOR_B', 'rx', 'reconciliation']) }}

with latest_rx as (
    select max(release_date) as release_date from {{ ref('stg_payor__uhc_rx') }}
),

latest_medical as (
    select *
    from {{ ref('stg_payor__uhc_claims') }}
    where release_date = (
        select max(release_date) from {{ ref('stg_payor__uhc_claims') }}
    )
      and service_date_first is not null
      and plan_paid_amount is not null
),

expected as (
    select
        count(*) as rows,
        sum(r.plan_paid_amount) as paid_amount
    from {{ ref('stg_payor__uhc_rx') }} r
    where r.release_date = (select release_date from latest_rx)
      and r.part_b_or_d = 'B'
      and r.fill_date is not null
      and r.plan_paid_amount is not null
),

strong_overlap as (
    select count(*) as rows
    from {{ ref('stg_payor__uhc_rx') }} r
    inner join latest_medical m
        on trim(m.member_alt_id) = trim(r.member_alt_id)
        and m.service_date_first = r.fill_date
        and m.claim_audit_number = r.audit_number
        and m.plan_paid_amount = r.plan_paid_amount
    where r.release_date = (select release_date from latest_rx)
      and r.part_b_or_d = 'B'
),

actual as (
    select
        count(*) as rows,
        sum(plan_paid_amount) as paid_amount,
        sum(case when rx_part_d_indicator = 'Y' then 1 else 0 end) as part_d_rows
    from {{ ref('int_spend__claims_detail') }}
    where payor = 'PAYOR_B'
      and source_claim_type = 'pharmacy'
)

select
    e.rows as expected_rows,
    a.rows as actual_rows,
    e.paid_amount as expected_paid_amount,
    a.paid_amount as actual_paid_amount,
    a.part_d_rows,
    o.rows as strong_overlap_rows
from expected e
cross join actual a
cross join strong_overlap o
where e.rows <> a.rows
   or abs(coalesce(e.paid_amount, 0) - coalesce(a.paid_amount, 0)) > 0.01
   or a.part_d_rows <> 0
   or o.rows <> 0
