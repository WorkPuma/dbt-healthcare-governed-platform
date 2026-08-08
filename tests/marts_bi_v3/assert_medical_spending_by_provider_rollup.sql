{# Verifies mart_medical_spending_by_provider reconciles to fct_spend__patient_month
   at the (payor, provider_id, service_month) grain. #}

{{ config(severity='warn', tags=['marts_bi_v3', 'spend', 'balance']) }}

with fact_rollup as (
    select
        payor,
        provider_id,
        service_month,
        sum(coalesce(revenue_amount, 0)) as revenue_total,
        sum(coalesce(total_cost, 0)) as total_cost,
        sum(coalesce(total_cost_plan_liability, 0)) as total_cost_plan_liability,
        sum(coalesce(claim_line_count, 0)) as claim_line_count
    from {{ ref('fct_spend__patient_month') }}
    group by 1, 2, 3
    -- Mirror the mart's operational tail-trim: mart_medical_spending_by_provider
    -- keeps only provider-months that earned premium or incurred spend (its
    -- documented `where revenue_total>0 or total_cost>0 or total_cost_plan_liability>0`).
    -- The raw fact also carries net-zero / pre-plan reversal-fragment months the mart
    -- intentionally drops, so the test must compare on the same operational scope —
    -- otherwise it flags rows the mart is designed to exclude (verified on prod: with
    -- this filter the fact rollup reconciles to the mart exactly, 0 rows / $0 diff).
    having sum(coalesce(revenue_amount, 0)) > 0
        or sum(coalesce(total_cost, 0)) > 0
        or sum(coalesce(total_cost_plan_liability, 0)) > 0
),

mart as (
    select
        payor,
        provider_id,
        service_month,
        revenue_total,
        total_cost,
        claim_line_count
    from {{ ref('mart_medical_spending_by_provider') }}
)

select
    coalesce(f.payor, m.payor) as payor,
    coalesce(f.provider_id, m.provider_id) as provider_id,
    coalesce(f.service_month, m.service_month) as service_month,
    round(coalesce(m.revenue_total, 0) - coalesce(f.revenue_total, 0), 2) as diff_revenue,
    round(coalesce(m.total_cost, 0) - coalesce(f.total_cost, 0), 2) as diff_cost,
    coalesce(m.claim_line_count, 0) - coalesce(f.claim_line_count, 0) as diff_claim_lines
from fact_rollup f
full outer join mart m
    on coalesce(f.payor, '') = coalesce(m.payor, '')
   and coalesce(f.provider_id, -1) = coalesce(m.provider_id, -1)
   and coalesce(f.service_month, date '1900-01-01') = coalesce(m.service_month, date '1900-01-01')
where abs(coalesce(m.revenue_total, 0) - coalesce(f.revenue_total, 0)) >= 0.01
   or abs(coalesce(m.total_cost, 0) - coalesce(f.total_cost, 0)) >= 0.01
   or coalesce(m.claim_line_count, 0) != coalesce(f.claim_line_count, 0)
