/*
  Domain test: paid revenue and paid cost on the spend fact must never be
  negative. Negative plan-paid usually signals an unreconciled claim reversal or
  a sign error in the source feed that would corrupt MLR/PMPM. Returns offending
  rows (0 = pass).
*/

select
    fct_spend__patient_month_id,
    revenue_amount,
    total_cost
from {{ ref('fct_spend__patient_month') }}
where coalesce(revenue_amount, 0) < 0
   or coalesce(total_cost, 0) < 0
