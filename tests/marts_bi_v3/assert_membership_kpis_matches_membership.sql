{# Verifies the KPI mart's current-month member panel reconciles to mart_membership.

   total_members_eom counts canonical BackendBaaS-or-Membership membership records per leaf
   dim-combo. The mart materializes ONLY leaf dim-combo rows — it carries no literal
   'All' rollup rows; the metric() runtime derives the all-filters 'All' total by
   SUM-ing over the leaf rows at query time. So the correct rollup invariant is:

       SUM(total_members_eom) over the current month's leaf rows
         == distinct canonical members in mart_membership.

   With clean (non-stale) leaf rows each Membership member maps to exactly one dim-combo,
   so the sum equals the distinct count. A drift means the KPI mart accumulated
   stale/duplicate dim-combo rows for a member whose dimensions churned between runs
   (the failure mode the mart's replace_where strategy is designed to prevent).

   NB: the previous version of this test filtered the seven dims to the literal value
   'All' (rows that do not exist in the materialized mart) and compared against the
   all-non-inactive account population — so it never reconciled regardless of the
   data. This version compares the matching Membership-member population against the real
   leaf-row rollup. #}

{{ config(severity='error', tags=['marts_bi_v3', 'membership', 'balance']) }}

with membership_count as (
    -- Canonical members = exactly the population total_members_eom counts.
    select count(distinct account_id) as total_members
    from {{ ref('mart_membership') }}
    where has_membership_record
),

kpis_rollup as (
    -- metric()'s all-filters 'All' total = SUM over every leaf dim-combo row for the
    -- current snapshot month (the mart stores leaf rows only, never 'All' rows).
    select sum(coalesce(total_members_eom, 0)) as total_members
    from {{ ref('mart_membership_kpis_monthly') }}
    where period_start = date_trunc('month', current_date())::date
)

select
    m.total_members as membership_total,
    k.total_members as kpis_total,
    coalesce(k.total_members, 0) - coalesce(m.total_members, 0) as diff
from membership_count m
cross join kpis_rollup k
where coalesce(k.total_members, 0) != coalesce(m.total_members, 0)
