/*
  Domain test (claims<->eligibility reconciliation): has_unmatched_cost flags a
  claim month with paid cost but NO paid MMR/PAYOR_B revenue record for that
  member-month (eligibility lag or an EMPI/crosswalk mapping gap). A small share
  is expected (timing); a large share means cost is systematically failing to join
  revenue, which corrupts book-level MLR.

  Severity: warn -- bounds the orphan-cost share across the fact.
  Returns a row only when the bound is exceeded (0 = pass).
*/

{{ config(severity='warn', tags=['spend', 'semantic_guardrail', 'reconciliation']) }}

{% set max_orphan_share = var('spend_orphan_cost_share', 0.25) %}

with agg as (
    select
        count(*)                                                  as n_rows,
        sum(case when has_unmatched_cost then 1 else 0 end)       as n_orphan
    from {{ ref('fct_spend__patient_month') }}
)

select
    n_rows,
    n_orphan,
    round(n_orphan * 1.0 / nullif(n_rows, 0), 4) as orphan_share,
    concat('Unmatched-cost member-months are ',
           round(n_orphan * 100.0 / nullif(n_rows, 0), 1),
           '% of the fact (> ', {{ max_orphan_share }} * 100,
           '% bound; claims not joining revenue)') as failure_message
from agg
where n_rows > 0
  and n_orphan * 1.0 / nullif(n_rows, 0) > {{ max_orphan_share }}
