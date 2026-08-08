/*
  Test: GHOST floor token share bounded — WARN

  Members without an EMPI cluster receive a deterministic GHOST:<payor>:<member>
  identity_id in spend/finance models. These are expected for roster-only ghosts
  but should remain a small minority of paid member-months. A spike signals EMPI
  matching regression or premature H-number churn creating duplicate identities.

  Threshold: GHOST floor tokens must be < 15% of paid PAYOR_A+PAYOR_B member-month rows
  in fct_spend__patient_month (revenue_amount > 0).
*/

{{ config(severity='warn', tags=['empi', 'spend', 'ghost']) }}

with paid as (
    select
        count(*)                                                    as paid_rows,
        sum(case when identity_id like 'GHOST:%' then 1 else 0 end) as ghost_rows
    from {{ ref('fct_spend__patient_month') }}
    where payor in ('PAYOR_A', 'PAYOR_B')
      and revenue_amount > 0
)

select
    paid_rows,
    ghost_rows,
    round(100.0 * ghost_rows / nullif(paid_rows, 0), 2)           as ghost_pct
from paid
where ghost_rows / nullif(paid_rows, 0) > 0.15
