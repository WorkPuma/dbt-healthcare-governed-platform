/*
  Domain test (derived economics): the MLR columns must equal their definitions.
    mlr                = round(total_cost / revenue_amount, 4)
    mlr_plan_liability = round(total_cost_plan_liability / revenue_amount, 4)
  Checked only where revenue_amount <> 0 (both are NULL otherwise by design).
  Catches a refactor that breaks the ratio or wires the wrong numerator.

  Returns offending rows (0 = pass).
*/

select
    fct_spend__patient_month_id,
    revenue_amount,
    total_cost,
    total_cost_plan_liability,
    mlr,
    mlr_plan_liability
from {{ ref('fct_spend__patient_month') }}
where coalesce(revenue_amount, 0) <> 0
  and (
        abs(coalesce(mlr, -999) - round(total_cost / revenue_amount, 4)) > 1e-6
     or abs(coalesce(mlr_plan_liability, -999)
            - round(total_cost_plan_liability / revenue_amount, 4)) > 1e-6
  )
