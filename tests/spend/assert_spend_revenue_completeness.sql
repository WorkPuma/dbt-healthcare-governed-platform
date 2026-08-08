/*
  Test: revenue completeness vs cost — WARN

  Flags payor service-months that carry material claims cost but lack a
  capitation revenue roster — i.e. a missing MMR/revenue file (see DEV-4386 for
  the PAYOR_A Jul/Aug/Oct/Nov/Dec 2025 gaps). WARN, not ERROR, because source-file
  delivery is outside our control; the gap should be closed by loading the file,
  not by failing the build. Elevate to ERROR once the upstream feed is reliable.

  Excludes the current still-posting month (recency = 1). A month "lacks a
  roster" when revenue members are < 25% of claimant members.
*/

{{ config(severity='warn', tags=['spend', 'finance', 'completeness']) }}

with monthly as (
    select
        payor,
        service_month,
        sum(revenue_amount)                                              as rev,
        sum(total_cost)                                                  as cost,
        count(distinct case when revenue_amount > 0 then patient_id end) as rev_mbr,
        count(distinct case when total_cost   > 0 then patient_id end)   as cost_mbr
    from {{ ref('fct_spend__patient_month') }}
    group by payor, service_month
),

scoped as (
    select
        *,
        row_number() over (partition by payor order by service_month desc) as recency
    from monthly
    where cost > 50000
)

select
    payor,
    service_month,
    round(rev, 0)  as revenue,
    round(cost, 0) as cost,
    rev_mbr,
    cost_mbr,
    'Material cost but capitation roster largely absent (missing MMR file? see DEV-4386)' as warning_reason
from scoped
where recency > 1
  and rev_mbr < 0.25 * cost_mbr
