{# Verifies mart_payor_unmatched_summary is a lossless rollup of mart_payor_unmatched_members. #}

{{ config(severity='error', tags=['marts_bi_v3', 'spend', 'balance']) }}

with detail_rollup as (
    select
        payor,
        count(*) as ghost_members,
        sum(coalesce(member_months, 0)) as ghost_member_months,
        sum(coalesce(revenue_total, 0)) as ghost_revenue,
        sum(coalesce(cost_total, 0)) as ghost_cost
    from {{ ref('mart_payor_unmatched_members') }}
    group by 1

    union all

    select
        'All' as payor,
        count(*) as ghost_members,
        sum(coalesce(member_months, 0)) as ghost_member_months,
        sum(coalesce(revenue_total, 0)) as ghost_revenue,
        sum(coalesce(cost_total, 0)) as ghost_cost
    from {{ ref('mart_payor_unmatched_members') }}
),

mart as (
    select
        payor,
        ghost_members,
        ghost_member_months,
        ghost_revenue,
        ghost_cost
    from {{ ref('mart_payor_unmatched_summary') }}
)

select
    coalesce(d.payor, m.payor) as payor,
    coalesce(m.ghost_members, 0) - coalesce(d.ghost_members, 0) as diff_members,
    coalesce(m.ghost_member_months, 0) - coalesce(d.ghost_member_months, 0) as diff_member_months,
    round(coalesce(m.ghost_revenue, 0) - coalesce(d.ghost_revenue, 0), 2) as diff_revenue,
    round(coalesce(m.ghost_cost, 0) - coalesce(d.ghost_cost, 0), 2) as diff_cost
from detail_rollup d
full outer join mart m on d.payor = m.payor
where coalesce(m.ghost_members, 0) != coalesce(d.ghost_members, 0)
   or coalesce(m.ghost_member_months, 0) != coalesce(d.ghost_member_months, 0)
   or abs(coalesce(m.ghost_revenue, 0) - coalesce(d.ghost_revenue, 0)) >= 0.01
   or abs(coalesce(m.ghost_cost, 0) - coalesce(d.ghost_cost, 0)) >= 0.01
