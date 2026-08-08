{{
  config(
    schema='raf_staging',
    tags=['raf', 'staging', 'athena']
  )
}}

/*
  Staging: Athena Claims

  Professional claims from Athena EHR. Each claim represents a
  submitted encounter with diagnosis codes that feed into RAF scoring.

  Source: athenaone.claim (via Athena staging catalog)
*/

with source as (
    select * from {{ source('athena_raf', 'claim') }}
),

renamed as (
    select
        cast(CLAIMID as int)                              as claim_id,
        cast(PATIENTID as int)                            as patient_id,
        cast(CLAIMAPPOINTMENTID as int)                   as appointment_id,
        SERVICEDEPARTMENTID                               as department_id,
        CLAIMCREATEDDATETIME                              as claim_created_date,
        CLAIMSERVICEDATE                                  as service_date,
        PRIMARYCLAIMSTATUS                                as claim_status,
        CLAIMPRIMARYPATIENTINSID                          as primary_insurance_id,
        CLAIMREFERRINGPROVIDERID                          as referring_provider_id,
        RENDERINGPROVIDERID                               as rendering_provider_id,
        SUPERVISINGPROVIDERID                             as supervising_provider_id
    from source
)

select * from renamed
