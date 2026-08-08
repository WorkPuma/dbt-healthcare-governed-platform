/*
  Test: PMPM (per-member-per-month) bands — ERROR

  Revenue PMPM and cost PMPM are the unit economics of the book. Out-of-band
  PMPM is the classic signature of a unit/fan-out bug (e.g. the crosswalk
  duplication we just fixed doubled revenue PMPM) or a member_months error.

  Scoped to revenue-complete + claims-mature months (same qualification as the
  MLR test) so we ERROR only where the base cost + revenue data exists; gap and
  IBNR-immature months are excluded.

  Bands (Medicare Advantage): revenue PMPM [300, 2500], cost PMPM [100, 3500].
  Passes = zero rows.
*/

{{ config(severity='error', tags=['spend', 'finance', 'pmpm', 'plausibility']) }}

with monthly as (
    select
        payor,
        service_month,
        sum(revenue_amount)                                              as rev,
        sum(total_cost)                                                  as cost,
        sum(member_months)                                               as mm,
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
    where cost > 0
),

qualified as (
    select
        payor,
        service_month,
        rev / nullif(mm, 0)  as rev_pmpm,
        cost / nullif(mm, 0) as cost_pmpm
    from scoped
    where rev > 0
      and rev_mbr >= 0.5 * cost_mbr
      and recency > 3
      and mm > 0
)

select
    payor,
    service_month,
    round(rev_pmpm, 0)  as rev_pmpm,
    round(cost_pmpm, 0) as cost_pmpm,
    case
        when rev_pmpm  < 300 or rev_pmpm  > 2500 then 'REV_PMPM_OUT_OF_BAND'
        when cost_pmpm < 100 or cost_pmpm > 3500 then 'COST_PMPM_OUT_OF_BAND'
    end as failure_reason
from qualified
where rev_pmpm  < 300 or rev_pmpm  > 2500
   or cost_pmpm < 100 or cost_pmpm > 3500
