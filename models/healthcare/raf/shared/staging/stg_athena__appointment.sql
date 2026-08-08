{{
  config(
    schema='raf_staging',
    tags=['raf', 'staging', 'athena']
  )
}}

/*
  Staging: Athena Appointments

  Appointment records from Athena EHR. Links claims to encounters
  and provides visit-level context (date, provider, department).

  Source: athenaone.appointment (via Athena staging catalog)
*/

with source as (
    select * from {{ source('athena_raf', 'appointment') }}
),

renamed as (
    select
        cast(APPOINTMENTID as int)                        as appointment_id,
        cast(PATIENTID as int)                            as patient_id,
        DEPARTMENTID                                      as department_id,
        PROVIDERID                                        as provider_id,
        APPOINTMENTDATE                                   as appointment_date,
        APPOINTMENTSTATUS                                 as appointment_status,
        APPOINTMENTTYPEID                                 as appointment_type_id,
        APPOINTMENTSCHEDULEDDATETIME                      as scheduled_datetime,
        APPOINTMENTCHECKINDATETIME                        as checkin_datetime,
        APPOINTMENTCHECKOUTDATETIME                       as checkout_datetime,
        APPOINTMENTDURATION                               as duration_minutes,
        -- Canonical "completed visit" = Athena status 2/3/4 (Checked In, Checked
        -- Out, Charge Entered). Source emits prefixed values like
        -- '4 - Charge Entered'; uses is_athena_completed_like macro so this
        -- stays aligned with healthcare_constants.sql definitions.
        case
            when {{ is_athena_completed_like('APPOINTMENTSTATUS') }} then true
            else false
        end                                               as is_completed
    from source
    -- Exclude open schedule slots (no patient assigned)
    where PATIENTID is not null
)

select * from renamed
