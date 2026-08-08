{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='provider_id',
        matched_condition='t.last_updated_at < s.last_updated_at',
        on_schema_change='append_new_columns',
        schema='healthcare',
        alias='providers',
        tags=['dimension', 'mdm', 'cube', 'BIPlatform']
    )
}}

/*
  providers -- Conformed Provider Dimension

  Single source of truth for provider attributes across metric views, BI marts,
  and fact models.
  Employment data (FTE, site leader, employment type) now sourced directly from
  MDM Provider at the stg_mdm__provider level.

  Grain: One row per Athena provider_id.
  Source: stg_mdm__provider (MDM-governed provider master)
*/

with athena_provider_groups as (
    select
        CAST(p.PROVIDERID AS BIGINT) as provider_id,
        CAST(p.PROVIDERGROUPID AS BIGINT) as provider_group_id,
        pg.PROVIDERGROUPNAME as provider_group_name
    from {{ source('athenahealth', 'provider') }} p
    left join {{ source('athenahealth', 'providergroup') }} pg
        on p.PROVIDERGROUPID = pg.PROVIDERGROUPID
    where p.DELETEDDATETIME is null
),

providers as (
    select
        -- Primary Key
        s.provider_id,

        -- Cross-System Identifiers
        s.salesforce_contact_id,
        s.trinet_employee_id,

        -- Provider Info
        s.provider_name,
        s.npi,
        s.credentials,
        s.provider_type,
        s.specialty,
        s.alias,
        s.midi_provider_names,

        -- Normalized payor-attributed-provider match keys.
        -- Used to join payor roster files (PAYOR_A, PAYOR_C, Payor Delta, MSSP)
        -- where only a name string is supplied and no NPI. Each entry is the
        -- canonical sort-tokenized form (see normalize_provider_name macro).
        -- Built from: canonical Athena name, "Last, First" variant, and any
        -- manually-curated MIDI/Athena spellings in midi_provider_names.
        array_distinct(
            filter(
                array_union(
                    array(
                        {{ normalize_provider_name('s.provider_name') }},
                        {{ normalize_provider_name(
                            "concat_ws(', ', "
                            "  regexp_extract(s.provider_name, '^(.*) ([^ ]+)$', 2), "
                            "  regexp_extract(s.provider_name, '^(.*) ([^ ]+)$', 1))"
                        ) }}
                    ),
                    coalesce(
                        transform(s.midi_provider_names,
                                  v -> {{ normalize_provider_name('v') }}),
                        array()
                    )
                ),
                k -> k is not null and length(k) > 0
            )
        ) as payor_match_keys,

        -- Classification Flags
        s.is_physician,
        s.is_mid_level,
        s.is_ancillary_staff,
        s.is_non_provider,
        s.is_bh_provider,

        -- Provider Group
        apg.provider_group_id,
        s.provider_group_name,

        -- Clinic Assignment
        s.assigned_clinic,
        case
            -- MDM dashboard_location_override wins (e.g. CMO Deb Dittberner -> 'CMO')
            when s.dashboard_location_override is not null then s.dashboard_location_override
            when s.assigned_clinic like '%Crystal%' then 'Crystal'
            when s.assigned_clinic like '%Eagan%' then 'Eagan'
            when s.assigned_clinic like '%Rosedale%' then 'Rosedale'
            when s.assigned_clinic like '%Highland%' then 'Highland Park'
            when s.assigned_clinic like '%Lyndale%' then 'Lyndale'
            when s.assigned_clinic like '%Behavioral%' or s.assigned_clinic like '%BH%' then 'Behavioral Health'
            when s.assigned_clinic = 'Inactive' then 'Inactive'
            else s.assigned_clinic
        end as clinic_standardized,

        -- Activity Metrics
        s.future_visit_count_30d,

        -- Employment
        s.hire_date,
        s.termination_date,
        s.continuous_service_start_date,
        s.continuous_service_end_date,
        s.is_active,

        -- HR / Employment
        s.business_title,
        s.is_site_leader,
        s.fte_hours,
        round(s.fte_hours / 40.0, 4)           as fte_pct,
        s.is_contractor,
        s.is_locum_tenens,
        s.has_trinet_match,
        s.employment_type,

        -- Good standing override (true = NOT in good standing for bonus)
        s.good_standing_false_bonus,

        -- Force bonus eligible override (hand-curated in MDM)
        s.force_bonus_eligible,

        -- Curated scorecard/bonus eligibility (hand-maintained in MDM).
        -- NULL = use downstream default/derived logic.
        s.scorecard_eligible,
        s.bonus_eligible,
        s.bonus_eligible_start_date,
        s.bonus_eligible_end_date,
        s.dashboard_location_override,
        s.is_float_provider,

        -- Organizational hierarchy (from TriNet)
        s.supervisor_id,
        s.supervisor_name,
        s.department_id,
        s.department_name,
        s.location_id,
        s.location_name,

        -- Provider type category (for bonus calculations)
        case
            when s.provider_type in ('MD', 'DO') then 'MD/DO'
            else 'APP'
        end                                   as type_category,

        -- Metadata
        s.source_system,
        s.last_updated_at

    from {{ ref('stg_mdm__provider') }} s
    left join athena_provider_groups apg
        on s.provider_id = apg.provider_id
)

select * from providers
