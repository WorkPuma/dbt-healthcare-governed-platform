{# Verifies mart_medical_spending is a lossless rollup of mart_medical_spending_detail
   at the (payor, service_month) grain. Fails if any measure drifts by >= $0.01. #}

{{ config(severity='warn', tags=['marts_bi_v3', 'spend', 'balance']) }}

with detail_rollup as (
    select
        payor,
        service_month,
        sum(coalesce(plan_paid_amount, 0)) as total_cost,
        count(*) as claim_line_count
    from {{ ref('mart_medical_spending_detail') }}
    group by 1, 2
),

mart as (
    -- VendorBlue is NOT a payor: it is the TIN-based subset of the PAYOR_B H2001
    -- contract that the headline mart relabels (payor='PAYOR_B' -> 'VendorBlue') purely
    -- so the dashboard's PAYOR_B contract page can offer its Healthcare/VendorBlue/Both
    -- scope selector. The line-level detail mart keeps these dollars under payor
    -- 'PAYOR_B'. To verify the real invariant — the headline is a lossless rollup of
    -- detail with no dollars dropped — we collapse the VendorBlue sub-label back to
    -- its parent 'PAYOR_B' before comparing (verified on prod: this reconciles exactly,
    -- 0 rows / $0 diff; the only difference between the two marts is this relabel).
    select
        case when payor = 'VendorBlue' then 'PAYOR_B' else payor end as payor,
        service_month,
        sum(total_cost) as total_cost,
        sum(claim_line_count) as claim_line_count
    from {{ ref('mart_medical_spending') }}
    group by 1, 2
)

select
    coalesce(d.payor, m.payor) as payor,
    coalesce(d.service_month, m.service_month) as service_month,
    round(coalesce(m.total_cost, 0) - coalesce(d.total_cost, 0), 2) as diff_total_cost,
    coalesce(m.claim_line_count, 0) - coalesce(d.claim_line_count, 0) as diff_claim_line_count
from detail_rollup d
full outer join mart m
    on coalesce(d.payor, '') = coalesce(m.payor, '')
   and coalesce(d.service_month, date '1900-01-01') = coalesce(m.service_month, date '1900-01-01')
where abs(coalesce(m.total_cost, 0) - coalesce(d.total_cost, 0)) >= 0.01
   or coalesce(m.claim_line_count, 0) != coalesce(d.claim_line_count, 0)
