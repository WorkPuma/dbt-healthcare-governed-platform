/*
  Domain test (Part D pharmacy isolation): Healthcare Org does not carry Part D
  risk, so total_cost_plan_liability must equal gross total_cost minus
  cost_part_d for every member-month. PAYOR_A "pharmacy" dollars are Part B
  (vaccines, CGM/DME, nebulizer drugs) and remain plan liability — only TRUE
  Part D (rx_part_d_indicator = Y, rolled into cost_part_d) is netted out.
  Guards the plan-liability column that MLR/TCOC plan-liability metrics use.

  Returns offending rows (0 = pass).
*/

select
    fct_spend__patient_month_id,
    total_cost,
    cost_part_d,
    total_cost_plan_liability,
    (coalesce(total_cost, 0) - coalesce(cost_part_d, 0)) as expected_plan_liability
from {{ ref('fct_spend__patient_month') }}
where abs(
        coalesce(total_cost_plan_liability, 0)
        - (coalesce(total_cost, 0) - coalesce(cost_part_d, 0))
    ) > 0.005
