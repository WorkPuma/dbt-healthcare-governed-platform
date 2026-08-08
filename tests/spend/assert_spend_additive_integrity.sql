/*
  Test: revenue additive integrity + member-month presence — ERROR

  Pure arithmetic invariants with no data-gap excuse, so these hard-fail:
    1. Where a payor splits revenue into Part A / Part B (PAYOR_A), the parts must
       reconcile to revenue_amount within $1. PAYOR_B ships no A/B split (both null)
       and is exempt.
    2. Any paid member-month (revenue_amount > 0) must carry >= 1 member_month,
       otherwise PMPM denominators and member counts are corrupt.

  Passes = zero rows.
*/

{{ config(severity='error', tags=['spend', 'finance', 'integrity']) }}

select
    payor,
    -- redact: opaque md5 surrogate, not the raw patient id, so test/failure
    -- artifacts carry no PHI. Rejoin to the fact via md5(cast(patient_id as string)).
    md5(cast(patient_id as string))  as patient_key,
    service_month,
    'PART_A_B_NOT_EQUAL_TOTAL'  as failure_reason
from {{ ref('fct_spend__patient_month') }}
where revenue_amount > 0
  and (revenue_part_a is not null or revenue_part_b is not null)
  and abs(coalesce(revenue_part_a, 0) + coalesce(revenue_part_b, 0) - revenue_amount) > 1.0

union all

select
    payor,
    md5(cast(patient_id as string)),
    service_month,
    'REVENUE_WITHOUT_MEMBER_MONTHS'
from {{ ref('fct_spend__patient_month') }}
where revenue_amount > 0
  and (member_months is null or member_months <= 0)
