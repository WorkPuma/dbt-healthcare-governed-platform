{{
  config(
    schema='raf_staging',
    tags=['raf', 'staging', 'athena']
  )
}}

/*
  Staging: Athena Chart Records

  Patient chart identifiers from Athena. Used by
  int_patient_chart_crosswalk to resolve chart_id
  to patient_id for HCC assessments that reference
  charts instead of patients directly.

  Source: athenaone.chart (via Athena staging catalog)
*/

with source as (
    select * from {{ source('athena_raf', 'chart') }}
),

renamed as (
    select
        cast(CHARTID as int)                              as chart_id,
        ENTERPRISEID                                      as enterprise_id,
        CHARTSHARINGGROUPID                               as chart_sharing_group_id,
        CREATEDDATETIME                                   as created_datetime,
        DELETEDDATETIME                                   as deleted_datetime
    from source
    -- Exclude soft-deleted charts so chart->patient resolution never maps a
    -- suggestion to a patient via a chart that was deleted in Athena.
    where DELETEDDATETIME is null
)

select * from renamed
