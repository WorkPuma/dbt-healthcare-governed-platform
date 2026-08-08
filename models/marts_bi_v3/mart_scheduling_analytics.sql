{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        schema='marts_bi_v3',
        alias='mart_scheduling_analytics',
        unique_key='mart_scheduling_analytics_id',
        on_schema_change='append_new_columns',
        tags=['marts_bi_v3', 'cube', 'BIPlatform', 'v3_synced']
    )
}}

SELECT
    MD5(CONCAT_WS('|', CAST(a.appointment_id AS STRING))) AS mart_scheduling_analytics_id,
    a.appointment_id,
    a.patient_id,
    a.provider_id,
    a.department_id,
    a.visit_category,
    a.is_completed,
    a.is_cancelled,
    a.is_no_show,
    a.is_initial_visit,
    a.is_awv,
    a.is_behavioral_health,
    a.is_telehealth,
    a.slot_status,
    a.npv_recovery_category,
    a.scheduled_by,
    a.appointment_date,
    a.scheduled_datetime,
    cast(a.appointment_month as date) as appointment_month,
    a.cancellation_category,
    a.is_truly_cancelled,
    a.is_rescheduled,
    p.patient_status AS patients_patient_status,
    p.tier AS patients_patient_tier,
    p.primary_payor AS patients_primary_payor,
    p.membership_enrollment AS patients_membership_enrollment,
    pr.assigned_clinic AS providers_clinic_name,
    cl.clinic_name AS clinics_clinic_name,
    cl.clinic_type AS clinics_clinic_type,
    -- Canonical filter dimensions shared across the three BH-summary marts so
    -- a single dashboard BH Provider / Clinic filter broadcasts to every
    -- metric (this mart powers the BH Monthly Visit Trends chart, BH-sliced).
    pr.provider_name AS bh_provider,
    cl.clinic_name AS clinic,
        CASE
            WHEN (a.is_behavioral_health = true) THEN a.appointment_id
            ELSE CAST(NULL AS DECIMAL)
        END AS bh_aid,
        CASE
            WHEN (a.is_completed = true) THEN a.appointment_id
            ELSE CAST(NULL AS DECIMAL)
        END AS completed_aid,
        CASE
            WHEN (a.is_cancelled = true) THEN a.appointment_id
            ELSE CAST(NULL AS DECIMAL)
        END AS cancelled_aid,
        CASE
            WHEN (a.is_no_show = true) THEN a.appointment_id
            ELSE CAST(NULL AS DECIMAL)
        END AS noshow_aid,
        CASE
            WHEN (a.slot_status = 'Open') THEN a.appointment_id
            ELSE CAST(NULL AS DECIMAL)
        END AS open_slot_aid,
        CASE
            WHEN (a.slot_status = 'Filled') THEN a.appointment_id
            ELSE CAST(NULL AS DECIMAL)
        END AS filled_slot_aid,
    -- CDF watermark — required for ServingDB TRIGGERED sync (servingdb_sync.py:849)
    GREATEST(
        COALESCE(a.source_updated_at, TIMESTAMP '1900-01-01'),
        COALESCE(p.last_updated_at, TIMESTAMP '1900-01-01'),
        COALESCE(pr.last_updated_at, TIMESTAMP '1900-01-01'),
        COALESCE(cl.last_updated_at, TIMESTAMP '1900-01-01')
    ) AS source_updated_at
   FROM {{ ref('appointments') }} a
     LEFT JOIN {{ ref('patients') }} p ON (a.patient_id = CAST(p.patient_id AS DECIMAL))
     LEFT JOIN {{ ref('providers') }} pr ON (a.provider_id = pr.provider_id)
     LEFT JOIN {{ ref('clinics') }} cl ON (a.department_id = cl.department_id)
-- READ-gate (incremental runs only): scan only rows whose own record or joined
-- input changed since the last build, with a 24h late-arrival lookback. The
-- watermark is a computed alias, so the predicate references the underlying
-- columns directly. See V3 Developer Guide §1.3.
{% if is_incremental() %}
WHERE GREATEST(
        COALESCE(a.source_updated_at, TIMESTAMP '1900-01-01'),
        COALESCE(p.last_updated_at, TIMESTAMP '1900-01-01'),
        COALESCE(pr.last_updated_at, TIMESTAMP '1900-01-01'),
        COALESCE(cl.last_updated_at, TIMESTAMP '1900-01-01')
    ) >= (SELECT COALESCE(DATEADD(HOUR, -24, MAX(source_updated_at)), TIMESTAMP '1900-01-01') FROM {{ this }})
{% endif %}
