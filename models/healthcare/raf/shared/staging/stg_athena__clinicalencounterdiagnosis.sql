{{
  config(
    materialized='view',
    schema='raf_staging',
    tags=['raf', 'staging', 'athena']
  )
}}

/*
  Staging: Athena Clinical Encounter Diagnosis

  Clinical encounter-level diagnoses (broader than DX ICD-10).
  Used for supplemental diagnosis code capture and validation.

  Source: athenaone.clinicalencounterdiagnosis (via Athena staging catalog)
*/

with source as (
    select * from {{ source('athena_raf', 'clinicalencounterdiagnosis') }}
),

renamed as (
    select
        cast(CLINICALENCOUNTERDXID as int)                as clinical_encounter_dx_id,
        cast(CLINICALENCOUNTERID as int)                  as clinical_encounter_id,
        DIAGNOSISCODE                                     as diagnosis_code,
        cast(SNOMEDCODE as bigint)                        as snomed_code,
        STATUS                                            as status,
        NOTE                                              as note,
        LATERALITY                                        as laterality,
        ORDERING                                          as ordering
    from source
)

select * from renamed
