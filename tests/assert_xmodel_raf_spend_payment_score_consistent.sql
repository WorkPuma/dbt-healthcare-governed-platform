/*
  Cross-model test (RAF <-> Spend): the payment RAF carried on the spend fact must
  match the source RAF fact. fct_spend__patient_month.payment_raf_score is joined
  from fct_raf__patient_summary on (patient_id, payment_year); if that join drifts
  (key type mismatch, stale RAF, wrong payment_year) the spend model's
  risk-adjusted TCOC and expected-revenue silently diverge from the official score.

  For every member-month with a non-null payment_raf_score, a RAF row must exist
  for the same (patient_id, payment_year) with an equal payment_raf_score.

  Returns offending member-months (0 = pass).
*/

with spend as (
    select distinct
        cast(patient_id as string) as patient_id,
        payment_year,
        cast(payment_raf_score as double) as payment_raf_score
    from {{ ref('fct_spend__patient_month') }}
    where payment_raf_score is not null
),

raf as (
    select
        cast(patient_id as string) as patient_id,
        payment_year,
        cast(payment_raf_score as double) as raf_payment_raf
    from {{ ref('fct_raf__patient_summary') }}
)

select
    s.patient_id,
    s.payment_year,
    s.payment_raf_score,
    r.raf_payment_raf
from spend s
left join raf r
    on r.patient_id = s.patient_id
    and r.payment_year = s.payment_year
where r.patient_id is null
   or r.raf_payment_raf is null
   or abs(s.payment_raf_score - r.raf_payment_raf) > 1e-6
