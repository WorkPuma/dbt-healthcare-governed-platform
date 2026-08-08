{{
  config(
    schema='raf_staging',
    tags=['raf', 'staging', 'athena']
  )
}}

/*
  Staging: Athena Clinical Encounters

  Clinical encounter records linking appointments to clinical
  documentation. Key join point for HCC assessments and
  diagnosis capture. Used by int_hccassessment and
  int_patient_code_by_encounter.

  Source: athenaone.clinicalencounter (via Athena staging catalog)
*/

with source as (
    select * from {{ source('athena_raf', 'clinicalencounter') }}
),

renamed as (
    select
        cast(CLINICALENCOUNTERID as int)                  as clinical_encounter_id,
        cast(PATIENTID as int)                            as patient_id,
        cast(APPOINTMENTID as int)                        as appointment_id,
        cast(CHARTID as int)                              as chart_id,
        ENCOUNTERDATE                                     as encounter_date,
        DEPARTMENTID                                      as department_id,
        PROVIDERID                                        as provider_id,
        ENCOUNTERSTATUS                                   as encounter_status,
        CLOSEDDATETIME                                    as closed_datetime,
        CREATEDDATETIME                                   as created_datetime,
        DELETEDBY                                         as deleted_by
    from source
    -- Exclude soft-deleted encounters (DELETEDBY set) so downstream RAF/CDIA
    -- models never date or support HCCs off an encounter deleted in Athena.
    where DELETEDBY is null
)

select * from renamed
