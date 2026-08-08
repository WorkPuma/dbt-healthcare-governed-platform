/*
  Test: claims maturity / IBNR flag — WARN (informational)

  The most recent cost-bearing months are not fully adjudicated (incurred-but-
  not-reported claims still developing), so their cost — and therefore MLR — is
  understated and should NOT be read as final. PAYOR_B illustrates the run-out:
  2026-01 MLR ~1.00 -> 2026-02 ~0.78 -> 2026-03 ~0.50 -> 2026-04 ~0.10.

  This surfaces the trailing 3 cost-months per payor as immature so dashboard
  consumers and the MLR/PMPM error tests (which exclude these) stay aligned.
  Always emits the trailing window; it is a visibility flag, not a failure.
*/

{{ config(severity='warn', tags=['spend', 'finance', 'ibnr', 'maturity']) }}

with cost_months as (
    select distinct payor, service_month
    from {{ ref('fct_spend__patient_month') }}
    where total_cost > 0
),

ranked as (
    select
        payor,
        service_month,
        row_number() over (partition by payor order by service_month desc) as recency
    from cost_months
)

select
    payor,
    service_month,
    recency,
    'Claims-immature month (IBNR run-out) — cost/MLR understated, not final'  as warning_reason
from ranked
where recency <= 3
