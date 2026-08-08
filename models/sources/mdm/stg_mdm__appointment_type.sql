{{
    config(
        tags=['mdm', 'appointment', 'reference']
    )
}}

with source as (
    select * from {{ ref('sync_mdm_appointment_type') }}
),

appointment_types as (
    select
        -- Primary Keys
        appointment_type_id,
        context_id,
        department_id,

        -- Type Info
        appointment_type_name,
        appointment_type_short_name,
        description,
        duration,

        -- Classification Flags
        AWV_Visit as is_awv_visit,
        Patient_Visit as is_patient_visit,
        Telehealth_Visit as is_telehealth_visit,
        Behavioral_Health_Visit as is_behavioral_health_visit,
        Ancillary_Visit as is_ancillary_visit,
        Initial_Visit as is_initial_visit,
        Routine_Visit as is_routine_visit,

        -- Scheduling
        web_schedulable_yn,
        patient_yn,

        -- Status
        deleted_yn,
        review_status,

        -- Metrics
        appointment_count,

        -- Metadata
        source_system,
        last_updated_at

    from source
    where deleted_yn = 'N'
)

select * from appointment_types
