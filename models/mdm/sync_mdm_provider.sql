{{
    config(
        alias='provider',
        incremental_strategy='merge',
        matched_condition='t.last_updated_at < s.last_updated_at',
        unique_key='provider_id',
        on_schema_change='append_new_columns',
        merge_exclude_columns=['salesforce_contact_id', 'Physician', 'Mid_Level',
                               'Ancillary_Staff', 'Non_Provider', 'Alias',
                               'BH_Provider', 'force_bonus_eligible',
                               'MIDI_Provider_Names',
                               'scorecard_eligible', 'bonus_eligible',
                               'bonus_eligible_start_date', 'bonus_eligible_end_date',
                               'dashboard_location_override', 'is_float_provider'],
        post_hook=[
            "
            -- One-time, idempotent backfill of the curated eligibility columns
            -- from ref_provider_eligibility. The main MERGE seeds these only on
            -- INSERT and merge-excludes them on UPDATE (to preserve hand edits),
            -- so on a pre-existing table (prod, long-lived dev) the columns are
            -- added NULL by append_new_columns and would never populate. This
            -- hook fills ONLY the still-NULL cells, so hand-maintained values are
            -- never overwritten and, once backfilled, no further rows match
            -- (no CDF churn on subsequent runs).
            merge into {{ this }} t
            using {{ ref('ref_provider_eligibility') }} s
            on cast(t.provider_id as bigint) = cast(s.provider_id as bigint)
            when matched and (
                (t.scorecard_eligible is null and s.scorecard_eligible is not null)
                or (t.bonus_eligible is null and s.bonus_eligible is not null)
                or (t.bonus_eligible_start_date is null and s.bonus_eligible_start_date is not null)
                or (t.bonus_eligible_end_date is null and s.bonus_eligible_end_date is not null)
                or (t.dashboard_location_override is null and s.dashboard_location_override is not null)
                or (t.is_float_provider is null and s.is_float_provider is not null)
            ) then update set
                t.scorecard_eligible = coalesce(t.scorecard_eligible, s.scorecard_eligible),
                t.bonus_eligible = coalesce(t.bonus_eligible, s.bonus_eligible),
                t.bonus_eligible_start_date = coalesce(t.bonus_eligible_start_date, s.bonus_eligible_start_date),
                t.bonus_eligible_end_date = coalesce(t.bonus_eligible_end_date, s.bonus_eligible_end_date),
                t.dashboard_location_override = coalesce(t.dashboard_location_override, s.dashboard_location_override),
                t.is_float_provider = coalesce(t.is_float_provider, s.is_float_provider)
            "
        ],
        tags=['mdm', 'sync', 'provider']
    )
}}

/*
  sync_mdm_provider — Incremental MERGE into mdm.reference_data.provider

  MDM Provider is the single source of truth (keystone) for:
    - Provider identity (from Athena)
    - Clinic assignment (from scheduling, with past-appointment fallback)
    - Hire date, termination date, FTE, employment type (from TriNet HRIS)
    - Contractor/locum/good-standing overrides (from employment overrides seed)
        - is_active (Athena not-deleted AND not terminated per TriNet,
          with rehire carve-out when Athena hire_date is after TriNet term)

  Manually-curated MDM fields (merge-excluded, set outside this sync):
    - salesforce_contact_id, Physician, Mid_Level, Ancillary_Staff,
      Non_Provider, Alias, BH_Provider, force_bonus_eligible
    - scorecard_eligible, bonus_eligible, bonus_eligible_start_date,
      bonus_eligible_end_date, dashboard_location_override, is_float_provider
      (initial values seeded from ref_provider_eligibility on INSERT,
       hand-maintained in MDM and preserved on UPDATE via merge_exclude)

  Sources:
    - staging.v_provider_sync  (Athena identity + scheduling clinic, dbt-managed)
    - int_provider_trinet_crosswalk        (TriNet HRIS employment data)
    - ref_provider_employment_overrides    (manual corrections for non-TriNet providers)
    - ref_provider_eligibility             (initial scorecard/bonus eligibility seed)

  Grain: One row per provider_id
*/

with provider_sync as (
    select * from {{ ref('v_provider_sync') }}
),

trinet as (
    select * from {{ ref('int_provider_trinet_crosswalk') }}
),

overrides as (
    select
        cast(provider_id as bigint)           as provider_id,
        employment_type                        as override_employment_type,
        coalesce(is_contractor, false)         as override_is_contractor,
        coalesce(is_locum_tenens, false)       as override_is_locum_tenens,
        cast(termination_date as date)         as override_termination_date,
        cast(manual_fte_hours as int)          as override_fte_hours,
        coalesce(good_standing_false_bonus, false) as override_good_standing
    from {{ ref('ref_provider_employment_overrides') }}
),

eligibility as (
    select
        cast(provider_id as bigint)                  as provider_id,
        cast(scorecard_eligible as boolean)          as seed_scorecard_eligible,
        cast(bonus_eligible as boolean)              as seed_bonus_eligible,
        cast(bonus_eligible_start_date as date)      as seed_bonus_eligible_start_date,
        cast(bonus_eligible_end_date as date)        as seed_bonus_eligible_end_date,
        cast(dashboard_location_override as string)  as seed_dashboard_location_override,
        cast(is_float_provider as boolean)           as seed_is_float_provider
    from {{ ref('ref_provider_eligibility') }}
),

enriched as (
    select
        -- Identity (from Athena via v_provider_sync)
        vs.provider_id,
        vs.provider_name,
        vs.npi,
        vs.credentials,
        vs.provider_type,
        vs.specialty,

        -- TriNet linkage
        t.trinet_employee_id,
        (t.trinet_employee_id is not null)                        as has_trinet_match,

        -- Clinic assignment (from scheduling logic in v_provider_sync)
        vs.assigned_clinic,
        vs.future_visit_count_30d,

        -- Hire date: TriNet is authority, Athena is fallback.
        -- On rehire (Athena still active and Athena hire_date is after the
        -- prior TriNet termination), prefer Athena hire so we don't keep the
        -- old stint's start date as the current account's hire.
        case
            when t.trinet_termination_date is not null
                 and vs.is_active = true
                 and vs.hire_date is not null
                 and vs.hire_date > t.trinet_termination_date
                then vs.hire_date
            else coalesce(t.trinet_hire_date, vs.hire_date)
        end                                                       as hire_date,

        -- Termination date: TriNet > override seed. NO Athena fallback.
        -- Rehire carve-out: if Athena account is still active and its hire
        -- date is strictly after TriNet's termination, this is a new Athena
        -- provider_id / rehire (e.g. MIDI nstroud6 after nstroud3) — do NOT
        -- inherit the prior stint's termination or MDM will flip is_active
        -- false on every sync despite a live Athena login.
        case
            when coalesce(t.trinet_termination_date,
                          o.override_termination_date) is not null
                 and vs.is_active = true
                 and vs.hire_date is not null
                 and vs.hire_date > coalesce(t.trinet_termination_date,
                                            o.override_termination_date)
                then cast(null as date)
            else coalesce(t.trinet_termination_date,
                          o.override_termination_date)
        end                                                       as termination_date,

        -- Continuous service dates for proration calculations
        coalesce(t.trinet_original_hire_date,
                 t.trinet_hire_date,
                 vs.hire_date)                                    as continuous_service_start_date,
        case
            when coalesce(t.trinet_termination_date,
                          o.override_termination_date) is not null
                 and vs.is_active = true
                 and vs.hire_date is not null
                 and vs.hire_date > coalesce(t.trinet_termination_date,
                                            o.override_termination_date)
                then cast(null as date)
            else coalesce(t.trinet_termination_date,
                          o.override_termination_date)
        end                                                       as continuous_service_end_date,

        -- is_active: not deleted in Athena AND not terminated per TriNet/overrides
        -- (with the same rehire carve-out as termination_date above).
        case
            when vs.is_active = false then false
            when coalesce(t.trinet_termination_date,
                          o.override_termination_date) is not null
                 and coalesce(t.trinet_termination_date,
                              o.override_termination_date) < current_date()
                 and not (
                     vs.is_active = true
                     and vs.hire_date is not null
                     and vs.hire_date > coalesce(t.trinet_termination_date,
                                                o.override_termination_date)
                 )
                then false
            else true
        end                                                       as is_active,

        -- Business title from TriNet
        t.trinet_business_title                                   as business_title,

        -- FTE hours: override seed > TriNet > default 40
        coalesce(
            o.override_fte_hours,
            case when t.trinet_standard_hours > 1
                 then cast(t.trinet_standard_hours as int)
            end,
            40
        )                                                         as fte_hours,

        -- Site leader: inferred from TriNet business title
        coalesce(
            lower(t.trinet_business_title) like '%site provider lead%'
            or lower(t.trinet_business_title) like '%clinical training lead%',
            false
        )                                                         as is_site_leader,

        -- Employment classification
        coalesce(o.override_is_contractor, false)                 as is_contractor,
        coalesce(o.override_is_locum_tenens, false)               as is_locum_tenens,
        case
            when o.override_employment_type is not null then o.override_employment_type
            when t.trinet_employee_id is not null       then 'W2'
            else 'UNKNOWN'
        end                                                       as employment_type,

        -- Good standing override
        coalesce(o.override_good_standing, false)                 as good_standing_false_bonus,

        -- Organizational hierarchy (from TriNet)
        t.trinet_supervisor_id                                    as supervisor_id,
        t.trinet_supervisor_name                                  as supervisor_name,
        t.trinet_department_id                                    as department_id,
        t.trinet_department_name                                  as department_name,
        t.trinet_location_id                                      as location_id,
        t.trinet_location_name                                    as location_name,

        -- Provider Group (from Athena via v_provider_sync)
        vs.provider_group_name,

        -- Metadata
        vs.source_system,
        vs.last_updated_at,

        -- Manually-curated fields: NULL on insert, preserved on update via merge_exclude
        CAST(NULL AS STRING)  AS salesforce_contact_id,
        CAST(NULL AS BOOLEAN) AS Physician,
        CAST(NULL AS BOOLEAN) AS Mid_Level,
        CAST(NULL AS BOOLEAN) AS Ancillary_Staff,
        CAST(NULL AS BOOLEAN) AS Non_Provider,
        CAST(NULL AS STRING)  AS Alias,
        CAST(NULL AS BOOLEAN) AS BH_Provider,
        CAST(NULL AS BOOLEAN) AS force_bonus_eligible,
        -- External MIDI/Athena provider name variants
        -- (e.g. ["AMY MURPHY, APRN", "Amy Murphy, APRN", "AMY MURPHY, APRN, NP"]).
        -- One MDM provider can have many spellings in the external feed; this
        -- array holds every accepted spelling for credentialing-match.
        -- Manually curated; preserved on merge.
        CAST(NULL AS ARRAY<STRING>) AS MIDI_Provider_Names,

        -- Eligibility fields: seeded initial values on INSERT (from
        -- ref_provider_eligibility), preserved on UPDATE via merge_exclude.
        -- NULL means "use downstream default/derived logic".
        --   scorecard_eligible NULL  -> provider IS on the scorecard (default true)
        --   bonus_eligible     NULL  -> fall back to derived roster eligibility
        e.seed_scorecard_eligible             AS scorecard_eligible,
        e.seed_bonus_eligible                 AS bonus_eligible,
        e.seed_bonus_eligible_start_date      AS bonus_eligible_start_date,
        e.seed_bonus_eligible_end_date        AS bonus_eligible_end_date,
        e.seed_dashboard_location_override    AS dashboard_location_override,
        e.seed_is_float_provider              AS is_float_provider

    from provider_sync vs
    left join trinet t on vs.provider_id = t.provider_id
    left join overrides o on vs.provider_id = o.provider_id
    left join eligibility e on vs.provider_id = e.provider_id
)

select * from enriched
