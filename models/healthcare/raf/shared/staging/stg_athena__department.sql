{{
  config(
    schema='raf_staging',
    tags=['raf', 'staging', 'athena']
  )
}}

/*
  Staging: Athena Departments

  Department reference data from Athena EHR. Used by
  int_patient_supplement for department assignment and
  dim_raf__attribution for care site context.

  Source: athenaone.department (via Athena staging catalog)
*/

with source as (
    select * from {{ source('athena_raf', 'department') }}
),

renamed as (
    select
        cast(DEPARTMENTID as int)                         as department_id,
        DEPARTMENTNAME                                    as department_name,
        DEPARTMENTCITY                                    as city,
        DEPARTMENTSTATE                                   as state,
        DEPARTMENTZIP                                     as zip_code,
        DEPARTMENTPHONE                                   as phone,
        DEPARTMENTFAX                                     as fax,
        DEPARTMENTADDRESS                                 as address,
        PLACEOFSERVICECODE                                as place_of_service_code,
        PLACEOFSERVICETYPE                                as place_of_service_type,
        PROVIDERGROUPID                                   as provider_group_id
    from source
)

select * from renamed
