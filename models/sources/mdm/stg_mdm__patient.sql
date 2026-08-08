{{
    config(
        tags=['mdm', 'patient', 'reference']
    )
}}

/*
  Staging model for MDM patient reference data.
  Note: Source contains duplicate patient_ids. Deduplication keeps the most recently updated record.

  Updated 2026-02-07: Added cancelled_appointment_count, total_appointment_count, golden_id, athena_enterprise_id
*/

with source as (
    select * from {{ ref('sync_mdm_patient') }}
),

-- Deduplicate source - 5 patient_ids have exact duplicates
deduplicated as (
    select
        *,
        row_number() over (
            partition by patient_id
            order by last_updated_at desc nulls last
        ) as _row_num
    from source
    where deleted_yn = 'N'
      and test_patient_yn = 'N'
),

patients as (
    select
        -- Primary Keys
        patient_id,
        salesforce_account_id,

        -- EMPI Golden Record
        golden_id,

        -- Demographics
        first_name,
        last_name,
        date_of_birth,
        gender,

        -- Status
        patient_status,
        deleted_yn,
        test_patient_yn,

        -- Salesforce Integration
        in_salesforce,

        -- Appointment Counts (from Salesforce rollup fields)
        completed_number as completed_appointment_count,
        future_number as future_appointment_count,
        cancelled_number as cancelled_appointment_count,
        total_number as total_appointment_count,

        -- Athena IDs
        athena_enterprise_id,

        -- Metadata
        source_system,
        last_updated_at

    from deduplicated
    where _row_num = 1
)

select * from patients
