{{
  config(
    schema='raf_staging',
    tags=['raf', 'staging', 'athena']
  )
}}

/*
  Staging: Athena Claim Diagnoses (unpivoted)

  Diagnosis codes (ICD-10-CM) attached to claims. These are the
  primary input for HCC mapping and RAF score calculation.

  The claim table stores up to 8 diagnoses in wide format
  (DIAGNOSIS1 through DIAGNOSIS8). This model unpivots them
  into a normalized long format with one row per claim-diagnosis.

  Known bugs from Snowflake pipeline:
    B3: Previous code used LIKE 'ICD-10' which also matched 'ICD-100...'
        Downstream consumers should use exact match on code_set.

  Source: athenaone.claim DIAGNOSIS1-8 columns (via Athena staging catalog)
*/

with source as (
    select * from {{ source('athena_raf', 'claim') }}
),

unpivoted as (
    {% for i in range(1, 9) %}
    select
        cast(CLAIMID as int)                              as claim_id,
        cast(PATIENTID as int)                            as patient_id,
        {{ i }}                                           as diagnosis_position,
        upper(trim(DIAGNOSIS{{ i }}))                     as diagnosis_code,
        CLAIMSERVICEDATE                                  as service_date
    from source
    where DIAGNOSIS{{ i }} is not null
      and trim(DIAGNOSIS{{ i }}) != ''
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
)

select * from unpivoted
