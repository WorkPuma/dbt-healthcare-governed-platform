{# Current-month dual-authority active membership must reconcile exactly between
   the account-grain and monthly KPI marts after the lineage build. #}

{{ config(severity='error', tags=['marts_bi_v3', 'membership', 'balance']) }}

with membership_active as (
    select count(distinct active_member_aid) as active_members
    from {{ ref('mart_membership') }}
),

kpis_active as (
    select sum(coalesce(active_members_eom, 0)) as active_members_eom
    from {{ ref('mart_membership_kpis_monthly') }}
    where period_start = date_trunc('month', current_date())::date
)

select
    m.active_members,
    k.active_members_eom,
    m.active_members - k.active_members_eom as active_diff
from membership_active m
cross join kpis_active k
where coalesce(m.active_members, 0) != coalesce(k.active_members_eom, 0)
