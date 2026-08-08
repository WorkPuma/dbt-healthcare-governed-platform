{{
  config(
    schema='raf_intermediate',
    tags=['raf', 'intermediate', 'legacy']
  )
}}

/*
  Intermediate: Patient Chart Crosswalk

  Replaces: TWICE.INTERTABLES.PATIENT_CHART_CROSSWALK
  Sources: athenaone.chart + athenaone.patient

  Maps patient IDs to chart IDs in Athena. The Databricks chart table
  does NOT have PATIENTID — it has ENTERPRISEID which joins to
  patient.ENTERPRISEID to resolve the patient_id. One patient can have
  multiple charts (e.g., across departments/providers).
*/

-- F7: read charts through staging (stg_athena__chart) so soft-deleted charts
-- (deleted_datetime set) never resolve a suggestion to a patient. Patient stays
-- on raw source (no soft-delete column consumed here).
with chart as (
    select
        chart_id,
        enterprise_id
    from {{ ref('stg_athena__chart') }}
),

patient as (
    select * from {{ source('athena_raf', 'patient') }}
),

crosswalk as (
    select
        cast(p.PATIENTID as int)                          as patient_id,
        -- staging already casts chart_id to int; keep the cast explicit so the
        -- crosswalk's output type is unchanged from the prior raw-source version.
        cast(c.chart_id as int)                           as chart_id,
        p.CURRENTDEPARTMENTID                             as department_id,
        p.PRIMARYPROVIDERID                               as provider_id,
        -- Dedup: one row per patient-chart combination
        row_number() over (
            partition by p.PATIENTID, c.chart_id
            order by c.chart_id
        )                                                 as rn
    from chart c
    inner join patient p
        on c.enterprise_id = p.ENTERPRISEID
    where p.PATIENTID is not null
      and c.chart_id is not null
)

select
    patient_id,
    chart_id,
    department_id,
    provider_id
from crosswalk
where rn = 1
