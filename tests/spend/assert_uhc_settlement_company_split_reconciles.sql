{{ config(severity='error', tags=['spend', 'finance', 'PAYOR_B', 'VendorBlue', 'settlement', 'reconciliation']) }}

/*
  Hard-fail: the per-company PAYOR_B settlement decomposition must sum back to the
  full-contract settlement statement, per release.

  mart_uhc_settlement_by_company splits the statement's per-PCP DETAIL rows into
  Healthcare / VendorBlue via the PCP->company crosswalk and also emits a 'Both'
  rollup. The sum of the non-Both company rows (which is what 'Both' is built
  from) must equal mart_uhc_settlement (the statement 'Total' rollup) for each
  release_month — otherwise the PCP detail rows don't reconcile to the network
  Total (crosswalk leakage, a dropped PCP, or a detail/Total mismatch).

  Tolerance: $1 per dollar measure, 0 member-months (members is an integer YTD
  count and must tie exactly).
*/

with split as (
    select
        release_month,
        sum(cms_revenue)          as cms_revenue,
        sum(revenue_allocated)    as revenue_allocated,
        sum(total_medical_cost)   as total_medical_cost,
        sum(member_months)        as member_months,
        sum(provider_share_amount) as provider_share_amount
    from {{ ref('mart_uhc_settlement_by_company') }}
    where company <> 'Both'
    group by release_month
),

total as (
    -- mart_uhc_settlement is one row per release_month, but aggregate defensively
    -- so a future grain change can never silently fan out this reconciliation.
    select
        release_month,
        sum(cms_revenue)           as cms_revenue,
        sum(revenue_allocated)     as revenue_allocated,
        sum(total_medical_cost)    as total_medical_cost,
        sum(member_months)         as member_months,
        sum(provider_share_amount) as provider_share_amount
    from {{ ref('mart_uhc_settlement') }}
    group by release_month
)

select
    coalesce(t.release_month, s.release_month) as release_month,
    s.cms_revenue        as split_cms_revenue,
    t.cms_revenue        as total_cms_revenue,
    s.total_medical_cost as split_cost,
    t.total_medical_cost as total_cost,
    s.member_months      as split_member_months,
    t.member_months      as total_member_months,
    case
        when t.release_month is null
            then 'company-split has a release_month absent from statement Total'
        when s.release_month is null
            then 'statement Total has a release_month absent from company-split'
        when abs(coalesce(s.cms_revenue, 0) - coalesce(t.cms_revenue, 0)) > 1
            then 'company-split CMS revenue != statement Total'
        when abs(coalesce(s.revenue_allocated, 0) - coalesce(t.revenue_allocated, 0)) > 1
            then 'company-split revenue allocated != statement Total'
        when abs(coalesce(s.total_medical_cost, 0) - coalesce(t.total_medical_cost, 0)) > 1
            then 'company-split recognized cost != statement Total'
        when abs(coalesce(s.member_months, 0) - coalesce(t.member_months, 0)) > 0
            then 'company-split member-months != statement Total'
        when abs(coalesce(s.provider_share_amount, 0) - coalesce(t.provider_share_amount, 0)) > 1
            then 'company-split provider share != statement Total'
    end as failure_reason
from total t
full outer join split s on s.release_month = t.release_month
where t.release_month is null
   or s.release_month is null
   or abs(coalesce(s.cms_revenue, 0) - coalesce(t.cms_revenue, 0)) > 1
   or abs(coalesce(s.revenue_allocated, 0) - coalesce(t.revenue_allocated, 0)) > 1
   or abs(coalesce(s.total_medical_cost, 0) - coalesce(t.total_medical_cost, 0)) > 1
   or abs(coalesce(s.member_months, 0) - coalesce(t.member_months, 0)) > 0
   or abs(coalesce(s.provider_share_amount, 0) - coalesce(t.provider_share_amount, 0)) > 1
