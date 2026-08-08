/*
  Domain test (Part D pharmacy incidental check): because Healthcare Org does not
  carry Part D risk, pharmacy claims in cost_pharmacy are expected to be
  INCIDENTAL. If pharmacy's share of gross total_cost is large, the bucket is
  likely catching mis-classified Part B / medical drugs (which ARE plan liability)
  rather than true incidental Part D, and netting it out of plan-liability would
  understate real cost.

  Severity: warn -- quantifies the share per payor and flags when it exceeds the
  incidental threshold for human review. Returns offending payors (0 = pass).
*/

{{ config(severity='warn', tags=['spend', 'semantic_guardrail', 'partd_pharmacy']) }}

{% set max_pharmacy_share = var('spend_partd_pharmacy_share', 0.15) %}

with agg as (
    select
        payor,
        sum(coalesce(cost_pharmacy, 0)) as pharmacy_cost,
        sum(coalesce(total_cost, 0))    as gross_cost
    from {{ ref('fct_spend__patient_month') }}
    group by payor
)

select
    payor,
    pharmacy_cost,
    gross_cost,
    round(pharmacy_cost / nullif(gross_cost, 0), 4) as pharmacy_share,
    concat('Pharmacy is ',
           round(pharmacy_cost * 100.0 / nullif(gross_cost, 0), 1),
           '% of gross cost for ', payor,
           ' (> ', {{ max_pharmacy_share }} * 100,
           '% incidental threshold; check for mis-bucketed Part B drugs)') as failure_message
from agg
where gross_cost > 0
  and pharmacy_cost / nullif(gross_cost, 0) > {{ max_pharmacy_share }}
