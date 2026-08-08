/*
  Every identity-year in the RAF revenue fact must retain the union of service
  months from all payor member ids resolved to that identity. This catches both
  dominant-member selection (lost disjoint months) and additive aggregation
  (double-counted overlapping months).

  Passes = zero rows.
*/

with expected as (
    select
        payor,
        company,
        patient_id,
        payment_year,
        size(array_distinct(flatten(collect_list(service_months))))      as member_months,
        size(array_distinct(flatten(collect_list(base_service_months)))) as base_member_months
    from {{ ref('int_finraf__payor_paid_actuals') }}
    group by payor, company, patient_id, payment_year
),

actual as (
    select
        payor,
        company,
        patient_id,
        payment_year,
        member_months,
        base_member_months
    from {{ ref('fct_raf__member_revenue') }}
)

select
    coalesce(e.payor, a.payor)                 as payor,
    coalesce(e.company, a.company)             as company,
    coalesce(e.patient_id, a.patient_id)       as patient_id,
    coalesce(e.payment_year, a.payment_year)   as payment_year,
    e.member_months                            as expected_member_months,
    a.member_months                            as actual_member_months,
    e.base_member_months                       as expected_base_member_months,
    a.base_member_months                       as actual_base_member_months
from expected e
full outer join actual a
    on e.payor = a.payor
    and e.company = a.company
    and e.patient_id = a.patient_id
    and e.payment_year = a.payment_year
where e.patient_id is null
   or a.patient_id is null
   or e.member_months <> a.member_months
   or e.base_member_months <> a.base_member_months
