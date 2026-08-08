{{
    config(
        severity='error',
        tags=['marts_bi_v3', 'registry', 'data_quality']
    )
}}

/*
  Registry referential integrity: every metric_dimensions.metric_name must
  exist in metric_definitions.name — otherwise the dimension whitelist row
  is dead weight and the BFF can never serve it.

  History: 11 orphan metric_names found + resolved 2026-06-09 — sum_column /
  rate-denominator column names had been used where the metric name was
  intended (membership_kpis_monthly family):
    annual_plan_active_members_eom  -> renamed to annual_plan_active_members
    monthly_plan_active_members_eom -> renamed to monthly_plan_active_members
    mrr_total_dollars               -> renamed to membership_mrr
    mrr_paying_dollars              -> renamed to membership_mrr_paying
    paying_avg_tenure_months_eom    -> renamed to membership_paying_avg_tenure_months
    standard_members_eom            -> renamed to membership_standard_count
    paying_members_eom_prev         -> folded into paying_members_eom
    cancellation_30day_count_eom    -> deleted (dup of membership_cancellation_30_day_count rows)
    legacy_members_eom              -> deleted (dup of membership_legacy_count rows)
    ltv_paying_dollars              -> deleted (dup of membership_ltv_paying rows)
    membership_unique_patients_seen -> metric was genuinely missing; registered
                                       in metric_definitions (column existed +
                                       documented in the mart all along)
  Rows whose (target_metric, dimension) pair already existed were deleted as
  duplicates; the rest were renamed. Error severity from day one
  post-cleanup: a dangling whitelist row is always a registry bug.
*/

select distinct md.metric_name
from {{ ref('metric_dimensions') }} md
left join {{ ref('metric_definitions') }} d
    on md.metric_name = d.name
where d.name is null
