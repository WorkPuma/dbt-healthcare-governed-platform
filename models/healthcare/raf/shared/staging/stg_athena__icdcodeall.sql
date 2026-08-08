{{
  config(
    schema='raf_staging',
    tags=['raf', 'staging', 'athena']
  )
}}

/*
  Staging: Athena ICD Code Reference

  All ICD code definitions from Athena. Used for code validation,
  description lookup, and code-set filtering (ICD-10 vs ICD-9).

  FIX B3: Downstream consumers should filter on code_set = 'ICD-10'
  using exact match, not LIKE.

  Source: athenaone.icdcodeall (via Athena staging catalog)
*/

with source as (
    select * from {{ source('athena_raf', 'icdcodeall') }}
),

renamed as (
    select
        cast(ICDCODEID as int)                            as icd_code_id,
        upper(trim(DIAGNOSISCODE))                        as icd_code,
        DIAGNOSISCODEDESCRIPTION                          as description,
        upper(trim(DIAGNOSISCODESET))                     as code_set,
        UNSTRIPPEDDIAGNOSISCODE                           as unformatted_code,
        cast(DIAGNOSISCODESETID as int)                   as diagnosis_code_set_id
    from source
)

select * from renamed
