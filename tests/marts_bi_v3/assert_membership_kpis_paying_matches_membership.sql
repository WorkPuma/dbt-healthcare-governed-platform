{# DEV-4490: paying_billable_members_eom vs mart_membership Paying Member active count.

   paying_billable_members_eom = payment_status = 'Paying Member' AND active
   enrollment (Active Member / Active Member - Waived). Both sides use the same
   native payment_status gate (not payment_status_resolved). #}

{{ config(severity='error', tags=['marts_bi_v3', 'membership', 'balance']) }}

with membership_paying as (
    select count(distinct account_id) as paying_active_members
    from {{ ref('mart_membership') }}
    where payment_status = 'Paying Member'
      and enrollment_status in ('Active Member', 'Active Member - Waived')
),

kpis_paying as (
    select sum(coalesce(paying_billable_members_eom, 0)) as paying_billable_members_eom
    from {{ ref('mart_membership_kpis_monthly') }}
    where period_start = date_trunc('month', current_date())::date
)

select
    m.paying_active_members,
    k.paying_billable_members_eom,
    m.paying_active_members - k.paying_billable_members_eom as paying_diff
from membership_paying m
cross join kpis_paying k
where coalesce(m.paying_active_members, 0) != coalesce(k.paying_billable_members_eom, 0)
