{{
  config(
    enabled=false,
    schema='raf_staging',
    tags=['raf', 'staging', 'athena', 'deprecated'],
    meta={
      'deprecation_date': '2026-08-18',
      'deprecation_reason': (
        'Monthly dead-code audit: no dbt refs or external reads in 90d; '
        'downstream uses source()/seeds directly'
      ),
    },
  )
}}

/*
  Staging: Athena Appointment Types

  Reference table for appointment type definitions. Used by
  int_patient_code_by_encounter and gold_appointment_supplement
  to classify visit types and filter excluded appointment categories.

  Source: athenaone.appointmenttype (via Athena staging catalog)
*/

with source as (
    select * from {{ source('athena_raf', 'appointmenttype') }}
),

renamed as (
    select
        cast(APPOINTMENTTYPEID as int)                    as appointment_type_id,
        APPOINTMENTTYPENAME                               as appointment_type_name,
        APPOINTMENTTYPESHORTNAME                          as short_name,
        DURATION                                          as default_duration_minutes,
        GENERICYN                                         as is_generic
    from source
)

select * from renamed
