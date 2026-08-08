/*
  Cross-model test (Spend <-> Financial RAF): annual paid revenue must reconcile
  between the two facts that both derive from the PAYOR_A MMR. The spend model sums
  monthly revenue_amount (int_spend__member_month = PAYOR_A tot_ma_pmt) while
  fct_raf__member_revenue.paid_total_revenue is the same MMR capitation rolled to
  the year. They should tie within tolerance per member-year; a gap means one
  side dropped/duplicated MMR months or used a different identity resolution.

  Scoped to PAYOR_A only: per the fct_raf__member_revenue header, PAYOR_B paid revenue is
  a best-effort gross extract (not an MMR) and is NOT a reliable reconciliation
  basis. Checked above a materiality floor.

  Scoped to SCOREABLE payment years (ref_raf__data_collection_periods.is_scoreable):
  fct_raf__member_revenue is a projected-vs-paid fact and only exists for years we
  can score (PY2026+, given the Oct-2024 EMR data inception). Pre-scoreable paid
  revenue (e.g. PY2025, driven by prior-vendor CY2024-DOS diagnoses we do not hold)
  is real money but has no reproducible projection, so it is intentionally absent
  from this reconciliation fact and is tracked instead in the spend fact and
  int_finraf__payor_paid_actuals. Reconciling it here would compare raw paid dollars
  against a fact that, by design, does not cover those years.

  Severity: warn. Returns offending member-years (0 = pass).
*/

{{ config(severity='warn', tags=['spend', 'raf', 'reconciliation', 'cross_model']) }}

{% set rel_tol = var('xmodel_revenue_rel_tol', 0.02) %}
{% set min_revenue = var('xmodel_revenue_min', 1000) %}

with scoreable as (
    select payment_year
    from {{ ref('ref_raf__data_collection_periods') }}
    where is_scoreable = true
),

spend_rev as (
    select
        cast(patient_id as string) as patient_id,
        payment_year,
        sum(coalesce(revenue_amount, 0)) as spend_revenue
    from {{ ref('fct_spend__patient_month') }}
    where payor = 'PAYOR_A'
      -- Restrict to scoreable years up front so only relevant years are scanned /
      -- aggregated, rather than aggregating all history and filtering after the join.
      and payment_year in (select payment_year from scoreable)
    group by cast(patient_id as string), payment_year
),

raf_rev as (
    select
        cast(patient_id as string) as patient_id,
        payment_year,
        sum(coalesce(paid_total_revenue, 0)) as raf_revenue
    from {{ ref('fct_raf__member_revenue') }}
    where payor = 'PAYOR_A'
      and payment_year in (select payment_year from scoreable)
    group by cast(patient_id as string), payment_year
)

-- full outer join so a member-year present on only ONE side (the exact
-- dropped/duplicated-months symptom this test exists to catch) is surfaced as a
-- materially-large one-sided gap rather than silently filtered out by an inner join.
select
    coalesce(s.patient_id, r.patient_id)        as patient_id,
    coalesce(s.payment_year, r.payment_year)    as payment_year,
    coalesce(s.spend_revenue, 0)                as spend_revenue,
    coalesce(r.raf_revenue, 0)                  as raf_revenue,
    round(abs(coalesce(s.spend_revenue, 0) - coalesce(r.raf_revenue, 0)), 2) as abs_diff,
    concat('PAYOR_A paid revenue mismatch for patient ', coalesce(s.patient_id, r.patient_id),
           ' PY', cast(coalesce(s.payment_year, r.payment_year) as string),
           ': spend $', round(coalesce(s.spend_revenue, 0), 0),
           ' vs financial-RAF $', round(coalesce(r.raf_revenue, 0), 0)) as failure_message
from spend_rev s
full outer join raf_rev r
    on r.patient_id = s.patient_id
    and r.payment_year = s.payment_year
-- Both CTEs are already restricted to scoreable years, so no post-join year filter
-- is needed here.
where greatest(abs(coalesce(s.spend_revenue, 0)), abs(coalesce(r.raf_revenue, 0))) >= {{ min_revenue }}
  and abs(coalesce(s.spend_revenue, 0) - coalesce(r.raf_revenue, 0))
        / nullif(greatest(abs(coalesce(s.spend_revenue, 0)), abs(coalesce(r.raf_revenue, 0))), 0) > {{ rel_tol }}
