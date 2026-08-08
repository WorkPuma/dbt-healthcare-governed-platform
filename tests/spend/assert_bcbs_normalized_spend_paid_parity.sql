/*
  Guard: PAYOR_A latest-release paid dollars must survive into spend detail.

  int_spend__claims_detail filters `claim_service_date is not null`. If staging
  or normalized leaves authoritative rows undated, gold still holds them but
  spend/BI silently lose the dollars. This test compares paid totals between
  int_payor__payor_alpha_claims_normalized (is_latest_release) and the PAYOR_A slice of
  int_spend__claims_detail. Also fails when the authoritative dataset is empty.

  Severity: error.
*/

{{ config(severity='error', tags=['spend', 'PAYOR_A', 'claims', 'parity']) }}

with normalized as (
    select
        count(*) as row_count,
        coalesce(sum(plan_paid_amount), 0) as paid
    from {{ ref('int_payor__payor_alpha_claims_normalized') }}
    where is_latest_release = true
      and plan_paid_amount is not null
),

spend as (
    select
        count(*) as row_count,
        coalesce(sum(plan_paid_amount), 0) as paid
    from {{ ref('int_spend__claims_detail') }}
    where payor = 'PAYOR_A'
      and plan_paid_amount is not null
)

select
    n.row_count as normalized_rows,
    s.row_count as spend_rows,
    n.paid as normalized_paid,
    s.paid as spend_paid,
    n.row_count - s.row_count as dropped_rows,
    n.paid - s.paid as dropped_paid,
    concat(
        'PAYOR_A normalized→spend paid loss: dropped ',
        cast(n.row_count - s.row_count as string), ' rows / $',
        cast(round(n.paid - s.paid, 2) as string),
        ' (normalized $', cast(round(n.paid, 2) as string),
        ' → spend $', cast(round(s.paid, 2) as string), ')'
    ) as failure_message
from normalized n
cross join spend s
where n.row_count = 0
   or abs(n.paid - s.paid) > 1
   or abs(n.row_count - s.row_count) > 0
