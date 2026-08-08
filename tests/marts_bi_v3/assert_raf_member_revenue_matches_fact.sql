{# Verifies mart_raf_member_revenue is a passthrough of fct_raf__member_revenue. #}

{{ config(severity='error', tags=['marts_bi_v3', 'raf', 'balance']) }}

with fact as (
    select
        patient_id,
        payment_year,
        payor,
        sum(coalesce(paid_total_revenue, 0)) as paid_total_revenue,
        sum(coalesce(projected_annual_revenue, 0)) as projected_annual_revenue
    from {{ ref('fct_raf__member_revenue') }}
    group by 1, 2, 3
),

mart as (
    select
        patient_id,
        payment_year,
        payor,
        paid_total_revenue,
        projected_annual_revenue
    from {{ ref('mart_raf_member_revenue') }}
)

select
    coalesce(f.patient_id, m.patient_id) as patient_id,
    coalesce(f.payment_year, m.payment_year) as payment_year,
    coalesce(f.payor, m.payor) as payor,
    round(coalesce(m.paid_total_revenue, 0) - coalesce(f.paid_total_revenue, 0), 2) as diff_paid,
    round(coalesce(m.projected_annual_revenue, 0) - coalesce(f.projected_annual_revenue, 0), 2) as diff_projected
from fact f
full outer join mart m
    on coalesce(f.patient_id, '') = coalesce(m.patient_id, '')
   and coalesce(f.payment_year, -1) = coalesce(m.payment_year, -1)
   and coalesce(f.payor, '') = coalesce(m.payor, '')
where abs(coalesce(m.paid_total_revenue, 0) - coalesce(f.paid_total_revenue, 0)) >= 0.01
   or abs(coalesce(m.projected_annual_revenue, 0) - coalesce(f.projected_annual_revenue, 0)) >= 0.01
