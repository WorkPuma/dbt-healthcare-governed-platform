/*
  Domain test: the category cost columns on fct_spend__patient_month must sum to
  total_cost for every member-month (no leakage / double-count in the category
  CASE). Allow a 1-cent rounding tolerance. Returns offending rows (0 = pass).
*/

-- coalesce every term: a single NULL would make the bare sum NULL and the
-- predicate UNKNOWN, letting a genuinely mismatched row slip past the test.
select
    fct_spend__patient_month_id,
    coalesce(total_cost, 0)                                   as total_cost,
    (coalesce(cost_inpatient, 0) + coalesce(cost_outpatient, 0)
     + coalesce(cost_emergency, 0) + coalesce(cost_professional, 0)
     + coalesce(cost_pharmacy, 0) + coalesce(cost_post_acute, 0)
     + coalesce(cost_other, 0))                               as component_sum
from {{ ref('fct_spend__patient_month') }}
where abs(
        coalesce(total_cost, 0)
        - (coalesce(cost_inpatient, 0) + coalesce(cost_outpatient, 0)
           + coalesce(cost_emergency, 0) + coalesce(cost_professional, 0)
           + coalesce(cost_pharmacy, 0) + coalesce(cost_post_acute, 0)
           + coalesce(cost_other, 0))
      ) > 0.01
