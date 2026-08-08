/*
  Test: orphan-cost share — WARN

  "Orphan cost" = claimant members with claims cost but no linked capitation
  revenue in that month. A high share points to an enrollment-timing / EMPI
  linkage gap (we pay claims for a member we can't tie to a capitation row).
  WARN: some orphaning is legitimate (churn, retro enrollment, claim/eligibility
  timing), and the proper monthly MLR already nets these against revenue-only
  members. Surfaced so the linkage rate is monitored, not silently growing.

  Only considers months with a real claimant population (> 50 claimant members)
  so tiny months don't flap. Flags share > 0.25.
*/

{{ config(severity='warn', tags=['spend', 'finance', 'linkage']) }}

with monthly as (
    select
        payor,
        service_month,
        count(distinct case when total_cost > 0 then patient_id end)                                   as cost_mbr,
        count(distinct case when total_cost > 0 and coalesce(revenue_amount, 0) = 0 then patient_id end) as cost_only_mbr
    from {{ ref('fct_spend__patient_month') }}
    group by payor, service_month
)

select
    payor,
    service_month,
    cost_mbr,
    cost_only_mbr,
    round(cost_only_mbr / nullif(cost_mbr, 0), 2)                                  as orphan_share,
    'Cost-only member share > 0.25 (claims without linked capitation revenue)'     as warning_reason
from monthly
where cost_mbr > 50
  and cost_only_mbr > 0.25 * cost_mbr
