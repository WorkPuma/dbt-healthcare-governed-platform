{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='appointment_id',
        matched_condition="coalesce(t.source_updated_at, timestamp '1900-01-01') < s.source_updated_at",
        on_schema_change='append_new_columns',
        schema='healthcare',
        alias='scheduling_capacity',
        tags=['fact', 'cube', 'BIPlatform', 'scheduling', 'capacity'],
        post_hook=[
            "DELETE FROM {{ this }} WHERE appointment_id NOT IN (SELECT APPOINTMENT_ID FROM {{ ref('vw_provider_capacity') }})"
        ]
    )
}}

{#
  MERGE-never-deletes phantom-row cleanup. vw_provider_capacity is the upstream
  populator for this fact; phantoms cascade from there when athena.appointment
  hard-deletes drop slots. 16 phantoms exposed once vw_provider_capacity itself
  was cleaned via its own post_hook (2026-04-30).
#}

/*
  fct_provider_capacity — Provider Scheduling Capacity Fact

  Wraps vw_provider_capacity (which INNER JOINs to gold providers and
  appointment_types dimensions) with conformed column names for BIPlatform /
  Lakeview / metric views.

  Grain: One row per appointment slot.
  Sources: vw_provider_capacity, clinics
*/

select
    -- Slot Identity
    s.APPOINTMENT_ID as appointment_id,

    -- Provider (from gold providers dim via vw_provider_capacity)
    s.PROVIDER_ID as provider_id,
    s.PROVIDER_NAME as provider_name,
    s.clinic_standardized as provider_clinic,
    s.Physician as is_physician,
    s.is_mid_level,
    s.assigned_clinic,
    s.provider_is_active,
    s.provider_termination_date,
    s.HAS_ASSIGNED_PROVIDER as has_assigned_provider,

    -- Location
    s.DEPARTMENT_NAME as department_name,
    dl.clinic_name,
    dl.is_patient_facing,

    -- Appointment Type (from gold appointment_types dim via vw_provider_capacity)
    s.APPOINTMENT_TYPE_NAME as appointment_type_name,
    s.visit_category,
    s.Patient_Visit as is_patient_visit,
    s.AWV_Visit as is_awv,
    s.Behavioral_Health_Visit as is_behavioral_health,
    s.Telehealth_Visit as is_telehealth,
    s.Ancillary_Visit as is_ancillary,

    -- Scheduling Status
    s.APPOINTMENT_DATE as appointment_date,
    s.APPOINTMENT_STATUS_RAW as appointment_status,
    case
        when {{ is_athena_open_slot('s.APPOINTMENT_STATUS_RAW') }} then 'Open'
        when {{ is_athena_scheduled('s.APPOINTMENT_STATUS_RAW') }} then 'Filled'
        when {{ is_athena_cancelled('s.APPOINTMENT_STATUS_RAW') }} then 'Cancelled'
        when {{ is_athena_completed('s.APPOINTMENT_STATUS_RAW') }} then 'Completed'
        else 'Other'
    end as slot_status,

    -- Slot flags
    case when {{ is_athena_open_slot('s.APPOINTMENT_STATUS_RAW') }} then true else false end as is_open_slot,
    case when {{ is_athena_scheduled('s.APPOINTMENT_STATUS_RAW') }} then true else false end as is_booked_slot,
    case when {{ is_athena_completed('s.APPOINTMENT_STATUS_RAW') }} then true else false end as is_completed_slot,
    case when {{ is_athena_cancelled('s.APPOINTMENT_STATUS_RAW') }} then true else false end as is_cancelled_slot,

    -- IV/NPV Classification
    case when lower(s.APPOINTMENT_TYPE_NAME) like '%initial%' then true else false end as is_initial_visit_slot,

    -- Forward-Looking
    case when s.APPOINTMENT_DATE >= current_date() then true else false end as is_future,
    datediff(s.APPOINTMENT_DATE, current_date()) as days_from_today,

    -- Duration
    s.APPOINTMENT_DURATION_MINUTES as slot_duration_minutes,

    -- Change tracking
    s.source_updated_at as source_updated_at

from {{ ref('vw_provider_capacity') }} s
left join {{ ref('clinics') }} dl
    on s.DEPARTMENT_ID = dl.department_id
