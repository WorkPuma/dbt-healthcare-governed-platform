{{
    config(
        materialized='incremental',
        incremental_strategy='merge',
        unique_key='department_id',
        matched_condition='t.last_updated_at < s.last_updated_at',
        on_schema_change='append_new_columns',
        schema='healthcare',
        alias='clinics',
        tags=['dimension', 'cube', 'BIPlatform']
    )
}}

/*
  clinics — Conformed Location/Clinic Dimension

  Standardizes department/clinic naming across metric views, BI marts, and
  fact models.
  Uses athenahealth department table as the source, enriched with
  patient-facing classification.

  Grain: One row per Athena department_id.
  Sources: athenahealth.athenaone.department

  Patient-Facing Clinics (6): Crystal, Eagan, Rosedale, Highland Park, Lyndale, Behavioral Health
  Excluded Departments: MIDI (mobile/outreach), Main Office (admin), Vaccine Clinic (vaccination-only)
*/

with departments as (
    select
        departmentid as department_id,
        departmentname as department_name,
        coalesce(lastupdated, lastmodifieddatetime, createddatetime) as last_updated_at,

        -- Standardize clinic names for uniform reporting
        case
            when departmentname like '%Crystal%' then 'Crystal'
            when departmentname like '%Eagan%' then 'Eagan'
            when departmentname like '%Rosedale%' then 'Rosedale'
            when departmentname like '%Highland%' then 'Highland Park'
            when departmentname like '%Lyndale%' then 'Lyndale'
            when departmentname like '%Behavioral%' or departmentname like '%BH%' then 'Behavioral Health'
            when departmentname like '%MIDI%' then 'MIDI'
            when departmentname like '%Main Office%' then 'Main Office'
            when departmentname like '%Vaccine%' then 'Vaccine Clinic'
            else departmentname
        end as clinic_name,

        -- Patient-facing flag: only clinics where patients have appointments
        case
            when departmentname like '%Crystal%' then true
            when departmentname like '%Eagan%' then true
            when departmentname like '%Rosedale%' then true
            when departmentname like '%Highland%' then true
            when departmentname like '%Lyndale%' then true
            when departmentname like '%Behavioral%' or departmentname like '%BH%' then true
            else false
        end as is_patient_facing,

        -- Clinic type classification
        case
            when departmentname like '%Behavioral%' or departmentname like '%BH%' then 'Behavioral Health'
            when departmentname like '%MIDI%' then 'Mobile/Outreach'
            when departmentname like '%Vaccine%' then 'Vaccination'
            when departmentname like '%Main Office%' then 'Administrative'
            when departmentname like '%Crystal%'
                or departmentname like '%Eagan%'
                or departmentname like '%Rosedale%'
                or departmentname like '%Highland%'
                or departmentname like '%Lyndale%' then 'Primary Care'
            else 'Other'
        end as clinic_type

    from {{ source('athenahealth', 'department') }}
)

select * from departments
{{ smart_incremental_filter('last_updated_at', lookback_hours=24) }}
