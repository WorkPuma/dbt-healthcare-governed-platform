{{
    config(
        tags=['mdm', 'provider', 'reference']
    )
}}

/*
  stg_mdm__provider -- MDM Provider staging (thin pass-through)

  Reads from the MDM provider table (sync_mdm_provider) which is now the
  single source of truth for all provider attributes: identity (Athena),
  employment (TriNet HRIS), clinic assignment (scheduling), and manual
  classifications (Physician, Mid_Level, BH_Provider, etc.).

  All TriNet enrichment and override logic lives in sync_mdm_provider.
  This staging model applies only the base filter (exclude non-providers)
  and exposes clean column names.

  Filter: Non_Provider = false (excludes test accounts, placeholders).
  NOTE: is_active is NOT filtered here — downstream models decide whether
  to include terminated providers (e.g., bonus models need them for Q1 clinic shares).
*/

select
    provider_id,
    salesforce_contact_id,
    trinet_employee_id,

    -- Provider Info
    provider_name,
    npi,
    credentials,
    provider_type,
    specialty,
    Alias                                   as alias,
    MIDI_Provider_Names                     as midi_provider_names,

    -- Classification Flags (manually curated in MDM)
    coalesce(Physician, false)              as is_physician,
    coalesce(Mid_Level, false)              as is_mid_level,
    coalesce(Ancillary_Staff, false)        as is_ancillary_staff,
    coalesce(Non_Provider, false)           as is_non_provider,
    coalesce(BH_Provider, false)            as is_bh_provider,

    -- Provider Group
    provider_group_name,

    -- Clinic Assignment (from scheduling logic in sync)
    assigned_clinic,
    future_visit_count_30d,

    has_trinet_match,

    -- Employment (from TriNet/overrides, consolidated in sync)
    hire_date,
    termination_date,
    continuous_service_start_date,
    continuous_service_end_date,
    is_active,
    business_title,
    is_site_leader,
    fte_hours,
    is_contractor,
    is_locum_tenens,
    employment_type,
    good_standing_false_bonus,
    coalesce(force_bonus_eligible, false) as force_bonus_eligible,

    -- Curated eligibility (initial values seeded from ref_provider_eligibility,
    -- hand-maintained in MDM thereafter). NULL = use downstream default/derived
    -- logic: scorecard_eligible NULL -> on scorecard; bonus_eligible NULL ->
    -- fall back to derived roster eligibility.
    scorecard_eligible,
    bonus_eligible,
    bonus_eligible_start_date,
    bonus_eligible_end_date,
    dashboard_location_override,
    -- Float provider flag (curated in MDM). Drives per-clinic weighting of
    -- episodic metrics for providers who split time across clinics.
    coalesce(is_float_provider, false)      as is_float_provider,

    -- Organizational hierarchy (from TriNet)
    supervisor_id,
    supervisor_name,
    department_id,
    department_name,
    location_id,
    location_name,

    -- Metadata
    source_system,
    last_updated_at

from {{ ref('sync_mdm_provider') }}
where coalesce(Non_Provider, false) = false
  and coalesce(provider_group_name, '') != 'MIDI'
