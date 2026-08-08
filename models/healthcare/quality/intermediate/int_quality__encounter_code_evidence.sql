-- intermediate — DEV-4296 · int_quality__encounter_code_evidence (V3 Databricks dbt)
-- One evidence branch of the funnel: ALL codes carried by an encounter diagnosis.
--   * SNOMED  — native inline on clinicalencounterdiagnosis (PRIMARY)
--   * ICD-10  — via dxicd10 -> icdcodeall lookup (inline diagnosiscode is NULL in 2026)
-- Joined to clinicalencounter for patient_id + encounter_date.
-- Common funnel schema: patient_id · code · code_type · date_of_service · code_raw · code_modifier
--                       · source_table · source_record_id · measurement_year
--                       · code_origin · source_method
-- YEAR-AGNOSTIC: measurement_year is derived; the 2026 hard filter is applied at the SPINE/consumer.
-- Deletes already dropped in the staging refs.
-- Layer: intermediate.

with ced as (
    select * from {{ ref('stg_athena__clinicalencounterdiagnosis') }}
),
enc as (
    select * from {{ ref('stg_athena__clinicalencounter') }}
),
dxicd as (
    select * from {{ ref('stg_athena__clinicalencounterdxicd10') }}
),
icd as (
    select * from {{ ref('stg_athena__icdcodeall') }}
),

snomed_evidence as (
    select
        enc.patient_id,
        cast(ced.snomed_code as string) as code,
        cast(null as string)            as code_modifier,
        cast(ced.snomed_code as string) as code_raw,
        'SNOMED'                        as code_type,
        enc.encounter_date              as date_of_service,
        'ENCOUNTER_DX_SNOMED'           as source_table,
        ced.clinical_encounter_dx_id    as source_record_id,
        enc.encounter_status            as encounter_status,
        enc.created_datetime            as create_date_raw
    from ced
    join enc on enc.clinical_encounter_id = ced.clinical_encounter_id
    where ced.snomed_code is not null
),

icd_evidence as (
    select
        enc.patient_id,
        replace(cast(icd.icd_code as string), '.', '') as code,
        cast(null as string)            as code_modifier,
        replace(cast(icd.icd_code as string), '.', '') as code_raw,
        'ICD10CM'                       as code_type,
        enc.encounter_date              as date_of_service,
        'ENCOUNTER_DX_ICD10'            as source_table,
        dxicd.clinical_encounter_dx_icd10_id as source_record_id,
        enc.encounter_status            as encounter_status,
        enc.created_datetime            as create_date_raw
    from dxicd
    join ced on ced.clinical_encounter_dx_id = dxicd.clinical_encounter_dx_id
    join enc on enc.clinical_encounter_id    = ced.clinical_encounter_id
    join icd on icd.icd_code_id              = dxicd.icd_code_id
    where icd.icd_code is not null
),

unioned as (
    select * from snomed_evidence
    union all
    select * from icd_evidence
)

select
    cast(patient_id as string)          as patient_id,
    cast(code as string)                as code,
    code_type,
    date_of_service,
    cast(code_raw as string)            as code_raw,
    code_modifier,
    source_table,
    source_record_id,
    year(date_of_service)               as measurement_year,
    'system'                            as code_origin,
    'encounter_dx'                      as source_method,
    case when upper(encounter_status) = 'CLOSED' then 'closed' else 'pending' end as order_status,
    case when upper(encounter_status) = 'CLOSED' then 'closed_encounter' else 'soft' end as evidence_provenance,
    cast(create_date_raw as date)       as create_date
from unioned
