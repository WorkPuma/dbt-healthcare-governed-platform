{{ config(severity='error', tags=['spend', 'finance', 'PAYOR_B', 'VendorBlue', 'reconciliation']) }}

/*
  Hard-fail: the Medical Spending dashboard's PAYOR_B + VendorBlue books must reconcile
  EXACTLY to the deduped patient-level PAYOR_B H2001 contract in fct_spend.

  VendorBlue members are now carried in the EMPI (almost all as ghosts) and flow
  through fct_spend under payor='PAYOR_B' just like the PAYOR_A members we hold no Athena
  id for. mart_medical_spending relabels the pure-VendorBlue identities to
  payor='VendorBlue' so the dashboard keeps the Healthcare / VendorBlue split from one
  source. This test guards against the regression we just removed: a parallel raw
  VendorBlue book unioned on top, which double-counted the contract. So
  SUM(mart PAYOR_B + mart VendorBlue) must equal SUM(fct_spend PAYOR_B) — no double-count,
  no leakage — over the same operational service months the mart keeps.

  Tolerance is $1 per measure to absorb decimal rounding only.
*/

with mart as (
    select
        sum(coalesce(revenue_total, 0)) as mart_revenue,
        sum(coalesce(total_cost, 0))    as mart_cost
    from {{ ref('mart_medical_spending') }}
    where payor in ('PAYOR_B', 'VendorBlue')
),

-- Reconstruct the contract from the single deduped source, applying the exact
-- operational-month filter mart_medical_spending uses, so the comparison is apples
-- to apples (the mart drops months with no positive revenue AND no positive cost).
fct_month as (
    select
        service_month,
        sum(coalesce(revenue_amount, 0))            as revenue_total,
        sum(coalesce(total_cost, 0))                as total_cost,
        sum(coalesce(total_cost_plan_liability, 0)) as total_cost_plan_liability
    from {{ ref('fct_spend__patient_month') }}
    where payor = 'PAYOR_B'
    group by service_month
),

fct as (
    select
        sum(revenue_total) as fct_revenue,
        sum(total_cost)    as fct_cost
    from fct_month
    where coalesce(revenue_total, 0) > 0
       or coalesce(total_cost, 0) > 0
       or coalesce(total_cost_plan_liability, 0) > 0
)

select
    coalesce(m.mart_revenue, 0) as mart_revenue,
    coalesce(f.fct_revenue, 0)  as fct_revenue,
    coalesce(m.mart_cost, 0)    as mart_cost,
    coalesce(f.fct_cost, 0)     as fct_cost,
    case
        when abs(coalesce(m.mart_revenue, 0) - coalesce(f.fct_revenue, 0)) > 1
            then 'PAYOR_B+VendorBlue revenue != fct_spend PAYOR_B revenue (double-count or leakage)'
        when abs(coalesce(m.mart_cost, 0) - coalesce(f.fct_cost, 0)) > 1
            then 'PAYOR_B+VendorBlue cost != fct_spend PAYOR_B cost (double-count or leakage)'
    end as failure_reason
from mart m
cross join fct f
where abs(coalesce(m.mart_revenue, 0) - coalesce(f.fct_revenue, 0)) > 1
   or abs(coalesce(m.mart_cost, 0) - coalesce(f.fct_cost, 0)) > 1
