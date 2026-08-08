/*
  Test: Medical Loss Ratio (MLR) plausibility — ERROR

  MLR = total medical cost / total premium (capitation) revenue. CMS requires MA
  plans to run >= 85% MLR; a healthy book sits ~0.80-0.95. We ERROR only on
  months where we genuinely hold BOTH a full capitation roster AND adjudicated
  claims (per request: elevate when the base cost + revenue data exists for the
  period). Two situations are deliberately EXCLUDED and handled by warn-level
  tests instead:
    - revenue-gap months (missing MMR file -> DEV-4386): no roster, MLR undefined
    - IBNR-immature trailing months (last 3): claims still adjudicating, cost
      understated, MLR artificially low (assert_spend_claims_maturity)

  MLR uses ALL revenue and ALL cost for the month (premium is paid for every
  capitated member, not just those who incurred claims).

  Band: [0.5, 1.5]. Passes = zero rows.
*/

{{ config(severity='error', tags=['spend', 'finance', 'mlr', 'plausibility']) }}

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
    where cost > 0
),

qualified as (
    select *
    from scoped
    where rev > 0
      and rev_mbr >= 0.5 * cost_mbr   -- full capitation roster present
      and recency > 3                 -- drop IBNR-immature trailing months
),

payor_mlr as (
    select payor, sum(cost) / nullif(sum(rev), 0) as mlr
    from qualified
    group by payor
)

select
    payor,
    round(mlr, 3)                                                                 as mlr,
    'MLR outside [0.5, 1.5] on revenue-complete, claims-mature months'            as failure_reason
from payor_mlr
where mlr < 0.5 or mlr > 1.5
