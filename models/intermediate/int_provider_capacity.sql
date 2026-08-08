{{
    config(
        tags=['intermediate', 'provider', 'scheduling']
    )
}}

/*
    Intermediate model for provider capacity and scheduling metrics.
    Combines provider reference data with appointment metrics.
*/

with providers as (
    select * from {{ ref('stg_mdm__provider') }}
),

appointment_types as (
    select * from {{ ref('stg_mdm__appointment_type') }}
),

appointments as (
    select * from {{ ref('stg_salesforce__appointment') }}
),

-- Aggregate appointments by provider (using Salesforce Contact ID)
-- Note: Uses centralized status definitions from healthcare_constants macro
provider_appointments as (
    select
        provider_id as salesforce_contact_id,  -- This is actually a Salesforce Contact ID
        count(*) as total_appointments,
        count(case when {{ is_completed_appointment('status') }} then 1 end) as completed_appointments,
        count(case when {{ is_cancelled_appointment('status') }} then 1 end) as cancelled_appointments,
        count(case when status = 'x' then 1 end) as no_show_appointments,  -- Salesforce status 'x'; not aligned with universal Athena classification
        count(case when start_datetime >= current_date() then 1 end) as future_appointments,
        count(case when start_datetime >= current_date()
                   and start_datetime < dateadd(day, 30, current_date()) then 1 end) as appointments_next_30_days,
        avg(duration_minutes) as avg_appointment_duration,
        min(start_datetime) as earliest_appointment,
        max(start_datetime) as latest_appointment
    from appointments
    where provider_id is not null
    group by provider_id
),

provider_capacity as (
    select
        -- Provider Info
        p.provider_id,
        p.salesforce_contact_id,
        p.provider_name,
        p.npi,
        p.credentials,
        p.provider_type,
        p.specialty,
        p.alias,

        -- Classification
        p.is_physician,
        p.is_mid_level,
        p.is_ancillary_staff,

        -- Assignment
        p.assigned_clinic,
        p.future_visit_count_30d as mdm_future_visits_30d,

        -- Employment
        p.hire_date,
        p.termination_date,
        p.is_active,

        -- Appointment Metrics
        coalesce(pa.total_appointments, 0) as total_appointments,
        coalesce(pa.completed_appointments, 0) as completed_appointments,
        coalesce(pa.cancelled_appointments, 0) as cancelled_appointments,
        coalesce(pa.no_show_appointments, 0) as no_show_appointments,
        coalesce(pa.future_appointments, 0) as future_appointments,
        coalesce(pa.appointments_next_30_days, 0) as appointments_next_30_days,
        pa.avg_appointment_duration,
        pa.earliest_appointment,
        pa.latest_appointment,

        -- Derived Metrics
        case
            when pa.total_appointments > 0
            then round(pa.completed_appointments * 100.0 / pa.total_appointments, 2)
            else null
        end as completion_rate,

        case
            when pa.total_appointments > 0
            then round(pa.cancelled_appointments * 100.0 / pa.total_appointments, 2)
            else null
        end as cancellation_rate,

        case
            when pa.total_appointments > 0
            then round(pa.no_show_appointments * 100.0 / pa.total_appointments, 2)
            else null
        end as no_show_rate,

        -- Metadata
        p.last_updated_at as provider_last_updated

    from providers p
    left join provider_appointments pa on p.salesforce_contact_id = pa.salesforce_contact_id
)

select * from provider_capacity
