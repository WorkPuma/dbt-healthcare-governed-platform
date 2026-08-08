{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='appointment_type_id',
        matched_condition='t.last_updated_at < s.last_updated_at',
        on_schema_change='append_new_columns',
        schema='healthcare',
        alias='appointment_types',
        tags=['dimension', 'mdm', 'cube', 'BIPlatform']
    )
}}

/*
  appointment_types — Conformed Appointment Type Dimension

  Standardizes appointment classification across metric views, BI marts, and
  fact models.
  Classification flags are maintained by data stewards via MDM Reference Data UI.

  Grain: One row per Athena appointment_type_id.
  Source: stg_mdm__appointment_type (MDM-governed appointment type master)

  Classification Definitions:
    - Patient Visit: Counts as a schedulable slot; patients can book into this type
    - AWV Visit: Annual Wellness Visit types (G0402, G0438, G0439 related)
    - Telehealth Visit: Virtual/remote visit types
    - Behavioral Health Visit: Mental health and behavioral health sessions
    - Ancillary Visit: Lab, imaging, and other non-provider encounters

  Completion Statuses (applied in fact models):
    - Completed: charged entered, Checked Out, Checked In
    - Scheduled: filled (future date)
    - Cancelled: Cancelled, x status
*/

with appointment_types as (
    select
        -- Primary Key
        appointment_type_id,
        context_id,
        department_id,

        -- Type Info
        appointment_type_name,
        appointment_type_short_name,
        description,
        duration,

        -- MDM Classification Flags (maintained by data stewards)
        is_awv_visit,
        is_patient_visit,
        is_telehealth_visit,
        is_behavioral_health_visit,
        is_ancillary_visit,

        -- Derived: Visit category for reporting
        case
            when is_awv_visit = true then 'AWV'
            when is_behavioral_health_visit = true
                or lower(coalesce(appointment_type_name, '')) rlike '(behavioral|behavioural|therapy|therapist|psych|psychiat|counsel|counselling|bh)'
                then 'Behavioral Health'
            when is_telehealth_visit = true then 'Telehealth'
            when is_ancillary_visit = true then 'Ancillary'
            when is_patient_visit = true then 'Office Visit'
            else 'Other'
        end as visit_category,

        -- Scheduling Flags
        web_schedulable_yn,
        patient_yn,

        -- MDM Review Status
        review_status,

        -- Usage Metrics
        appointment_count,

        -- Metadata
        source_system,
        last_updated_at

    from {{ ref('stg_mdm__appointment_type') }}
)

select * from appointment_types
{{ smart_incremental_filter('last_updated_at', lookback_hours=24) }}
