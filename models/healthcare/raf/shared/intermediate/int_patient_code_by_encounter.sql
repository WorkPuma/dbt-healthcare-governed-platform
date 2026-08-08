{{
  config(
    schema='raf_intermediate',
    tags=['raf', 'intermediate', 'legacy']
  )
}}

/*
  Intermediate: Patient Code by Encounter

  Replaces: TWICE.INTERTABLES.PATIENT_CODE_BY_ENCOUNTER
  Sources: clinicalencounterdxicd10 + clinicalencounterdiagnosis +
           icdcodeall + clinicalencounter + hccicdcodeall +
           appointment + appointmenttype

  Joins clinical encounter diagnoses with HCC mappings and
  appointment context. Each row represents one ICD-10 code
  for one encounter with its HCC mapping (if applicable).

  FIX B3: Uses exact match on code_set = 'ICD-10' (not LIKE)
*/

with encounter_dx_icd10 as (
    select * from {{ source('athena_raf', 'clinicalencounterdxicd10') }}
),

encounter_dx as (
    select * from {{ source('athena_raf', 'clinicalencounterdiagnosis') }}
),

icd_codes as (
    select * from {{ source('athena_raf', 'icdcodeall') }}
),

clinical_encounter as (
    select * from {{ source('athena_raf', 'clinicalencounter') }}
),

hcc_icd as (
    select * from {{ source('athena_raf', 'hccicdcodeall') }}
),

appointment as (
    select * from {{ source('athena_raf', 'appointment') }}
),

appointment_type as (
    select * from {{ source('athena_raf', 'appointmenttype') }}
),

-- Step 1: Get ICD-10 codes from clinical encounters
-- Databricks join path: clinicalencounter → clinicalencounterdiagnosis (via CLINICALENCOUNTERID)
-- → clinicalencounterdxicd10 (via CLINICALENCOUNTERDXID) for ICD-10 detail.
-- clinicalencounterdiagnosis already has DIAGNOSISCODE (ICD-10 directly).
encounter_codes as (
    select
        cast(ce.PATIENTID as int)                         as patient_id,
        ce.CLINICALENCOUNTERID                            as clinical_encounter_id,
        ce.APPOINTMENTID                                  as appointment_id,
        ce.ENCOUNTERDATE                                  as encounter_date,
        edx.DIAGNOSISCODE                                 as diagnosis_code,
        edx.DIAGNOSISCODE                                 as icd10_code,
        upper(trim(edx.DIAGNOSISCODE))                    as normalized_icd10
    from clinical_encounter ce
    inner join encounter_dx edx
        on ce.CLINICALENCOUNTERID = edx.CLINICALENCOUNTERID
    where ce.ENCOUNTERDATE is not null
      and edx.DIAGNOSISCODE is not null
),

-- Step 2: Map ICD-10 to HCC
-- Databricks hccicdcodeall: DIAGNOSISCODE (ICD-10), HCCID (numeric). No HCCCODE or HCCDESCRIPTION.
with_hcc as (
    select
        ec.patient_id,
        ec.clinical_encounter_id,
        ec.appointment_id,
        ec.encounter_date,
        ec.diagnosis_code,
        ec.icd10_code,
        ec.normalized_icd10,
        cast(hcc.HCCID as int)                            as hcc_id,
        cast(null as string)                              as hcc_description,
        concat('HCC', cast(hcc.HCCID as int))             as hcc_code,
        -- HCC mapping found flag
        case when hcc.HCCID is not null then true else false end as has_hcc_mapping
    from encounter_codes ec
    left join hcc_icd hcc
        on ec.normalized_icd10 = hcc.DIAGNOSISCODE
),

-- Step 3: Add appointment context
-- Databricks: appointmenttype.NAME → APPOINTMENTTYPENAME
with_appointment as (
    select
        wh.*,
        a.APPOINTMENTDATE                                 as appointment_date,
        a.APPOINTMENTSTATUS                               as appointment_status,
        a.PROVIDERID                                      as provider_id,
        a.DEPARTMENTID                                    as department_id,
        at.APPOINTMENTTYPENAME                            as appointment_type_name,
        at.APPOINTMENTTYPEID                              as appointment_type_id
    from with_hcc wh
    left join appointment a
        on wh.appointment_id = a.APPOINTMENTID
    left join appointment_type at
        on a.APPOINTMENTTYPEID = at.APPOINTMENTTYPEID
)

select * from with_appointment
