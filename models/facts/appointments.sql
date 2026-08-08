{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='appointment_id',
        matched_condition='''
            t.source_updated_at < s.source_updated_at
            or t.attributed_payor is distinct from s.attributed_payor
            or t.attributed_payor_as_of_month is distinct from s.attributed_payor_as_of_month
        ''',
        on_schema_change='append_new_columns',
        liquid_clustered_by=['appointment_id'],
        schema='healthcare',
        alias='appointments',
        tags=['fact', 'cube', 'BIPlatform', 'scheduling', 'appointments'],
        post_hook=[
            "DELETE FROM {{ this }} WHERE appointment_id NOT IN (SELECT appointment_id FROM {{ ref('vw_operating_review_appointments') }})"
        ]
    )
}}

/*
  fct_appointments — Canonical Appointment Fact

  Unified appointment fact built on vw_operating_review_appointments (the most
  comprehensive appointment model). Enriched with conformed dimension keys for
  patient identity, provider, location, insurance, and appointment type.

  Insurance: Uses a waterfall (claim billed → eligibility verified → appointment set)
  to determine the most accurate primary and secondary insurance for each appointment.
  Self-Pay and NULL resolve to 'No Insurance Set'.

  Grain: One row per appointment_id.
  Sources: vw_operating_review_appointments, patients, patient_identity,
           providers, clinics, appointment_types
*/

with appointments as (
    select * from {{ ref('vw_operating_review_appointments') }}
    {% if is_incremental() %}
    -- Incremental watermark: only recompute appointments whose source row changed
    -- since the last run, with a lookback overlap to absorb late-arriving updates.
    -- The MERGE still upserts by appointment_id against the full target, so old
    -- appointments updated today (e.g. payor backfills) are matched correctly and
    -- no duplicates are introduced. This bounds the expensive 6-way enrichment join
    -- to the changed slice instead of the entire appointment history every run.
    -- coalesce guards the empty-target case: an empty {{ this }} yields a NULL
    -- max(), and `>= NULL` would exclude every row (table stays empty until a
    -- full refresh). Falling back to 1900-01-01 makes an empty target rebuild
    -- fully, then resume bounded incremental runs.
    where source_updated_at >= (
        select coalesce(dateadd(day, -3, max(source_updated_at)), timestamp '1900-01-01')
        from {{ this }}
    )
    {% endif %}
),

-- Derive initial visit flag: first completed appointment per patient.
-- Computed over FULL history (not the incremental slice) so the first-completed
-- date is correct for every patient — this is a cheap 2-column scan + aggregate,
-- not the full enrichment join.
initial_visits as (
    select
        patient_id,
        min(case when is_completed then appointment_date end) as first_completed_date
    from {{ ref('vw_operating_review_appointments') }}
    group by patient_id
)

select
    -- Appointment Keys
    a.appointment_id,
    a.patient_id,
    a.provider_id,
    a.department_id,
    a.appointment_type_id,

    -- Conformed Dimension Keys (for BIPlatform / Lakeview / metric-view joins)
    dp.golden_id,
    coalesce(dpi.salesforce_id, dp.salesforce_id) as salesforce_id,
    dpi.enterprise_id,
    dpi.provider_group_id,
    dpi.chart_group_name,
    dprov.clinic_standardized as provider_clinic,

    -- Location
    dl.clinic_name,
    dl.is_patient_facing,
    dl.clinic_type,
    a.service_location,

    -- Provider
    a.provider_name,
    dprov.is_physician,
    dprov.is_mid_level,
    dprov.is_bh_provider,

    -- Appointment Type
    a.appointment_type_name,
    a.appointment_type_short_name,
    dat.visit_category,
    dat.duration as appointment_type_duration,

    -- Classification Flags
    a.is_npv,
    a.is_awv,
    a.is_telehealth,
    a.is_behavioral_health,
    a.is_open_slot,
    a.is_filled_slot,
    a.is_cancelled,
    a.is_checked_in,
    a.is_completed,
    a.is_no_show,
    a.is_future_appointment,
    case when a.appointment_date = iv.first_completed_date then true else false end as is_initial_visit,

    -- Time Dimensions
    a.appointment_date,
    a.appointment_week,
    a.appointment_month,
    a.appointment_year,
    a.appointment_start_time,
    a.appointment_duration_minutes,

    -- Scheduling Lifecycle
    a.scheduled_datetime,
    a.scheduled_by,
    a.cancelled_datetime,
    a.cancellation_week,
    a.cancellation_month,
    a.cancellation_reason,
    a.cancelled_by,
    a.rescheduled_to_appointment_id,
    a.reschedule_datetime,
    a.rescheduled_by,
    a.check_in_datetime,
    a.check_out_datetime,

    -- Insurance (waterfall: claim billed → eligibility → appointment)
    a.primary_insurance_name,
    dp.canonical_primary_payor_brand    as primary_payor,
    a.primary_insurance_category,
    a.primary_insurance_product_type,
    a.primary_insurance_source,
    a.secondary_insurance_name,
    a.secondary_insurance_category,

    -- Membership (from patients dimension — Salesforce Membership_Enrollment__c)
    dp.membership_enrollment            as membership_status,
    dp.member_category,
    dp.legacy_membership_eligible,

    -- Universal Cancellation Classification
    a.is_rescheduled,
    a.is_truly_cancelled,
    a.cancellation_category,

    -- NPV Recovery (NPV-scoped, 30-day window — Immediate via RESCHEDULEDAPPOINTMENTID)
    a.is_rescheduled_immediate,
    a.is_late_recovery,
    a.npv_recovery_category,
    a.slot_status,

    -- Reviewer-honored attributed payor as-of the appointment month
    -- (int_attribution_payor_slots_pit -> backendbaas attribution_decisions).
    pit.attributed_payor,
    pit.attributed_payor_as_of_month,

    -- Metadata
    a.source_updated_at

from appointments a
left join {{ ref('patients') }} dp
    on a.patient_id = dp.patient_id
left join {{ ref('patient_identity') }} dpi
    on dp.golden_id = dpi.golden_id
left join {{ ref('providers') }} dprov
    on a.provider_id = dprov.provider_id
left join {{ ref('clinics') }} dl
    on a.department_id = dl.department_id
left join {{ ref('appointment_types') }} dat
    on a.appointment_type_id = dat.appointment_type_id
left join initial_visits iv
    on a.patient_id = iv.patient_id
left join {{ ref('int_attribution_payor_slots_pit') }} pit
    on cast(a.patient_id as bigint) = pit.patient_id
   and date_trunc('month', a.appointment_date) = pit.target_month
