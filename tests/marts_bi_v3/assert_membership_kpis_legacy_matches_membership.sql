{{ config(severity='error', tags=['marts_bi_v3', 'membership', 'balance']) }}

with membership_legacy as (
    select count(distinct account_id) as legacy_active_members
    from {{ ref('mart_membership') }}
    where legacy_member_aid is not null
      and enrollment_status in ('Active Member', 'Active Member - Waived')
),

kpis_legacy as (
    select sum(coalesce(legacy_members_eom, 0)) as legacy_members_eom
    from {{ ref('mart_membership_kpis_monthly') }}
    where period_start = date_trunc('month', current_date())::date
)

select
    m.legacy_active_members,
    k.legacy_members_eom,
    m.legacy_active_members - k.legacy_members_eom as legacy_diff
from membership_legacy m
cross join kpis_legacy k
where coalesce(m.legacy_active_members, 0) != coalesce(k.legacy_members_eom, 0)
