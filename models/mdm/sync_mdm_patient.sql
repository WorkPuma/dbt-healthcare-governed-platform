{{
    config(
        alias='patient',
        incremental_strategy='merge',
        matched_condition='t.last_updated_at < s.last_updated_at',
        unique_key='patient_id',
        on_schema_change='ignore',
        merge_exclude_columns=['days_since_last_completed_visit',
                               'last_completed_visit_date',
                               'computed_status', 'status_reason'],
        post_hook=[
            "DELETE FROM {{ this }} WHERE patient_id NOT IN (SELECT patient_id FROM {{ ref('v_patient_sync') }} WHERE patient_id IS NOT NULL)"
        ],
        tags=['mdm', 'sync', 'patient']
    )
}}

/*
  sync_mdm_patient — Incremental MERGE into mdm.reference_data.patient

  Replaces the standalone MDM Patient Sync job that ran outside dbt.
  Now executes as part of `dbt build --target prod`, ensuring the MDM patient
  table is current before downstream models (int_patient_status_computed,
  stg_mdm__patient, vw_membership_patients, etc.) consume it.

  Source: dbt model v_patient_sync (sources/mdm/v_patient_sync.sql) — replaces
  the legacy Databricks-side view mdm.reference_data.v_patient_sync. Joins
  Athena patient, Salesforce appointment counts, and EMPI golden IDs.

  All Athena patients flow through MDM regardless of department so EMPI
  matching, Salesforce identity linkage, and golden-record resolution
  continue to work for MIDI / dept-10 / dept-11 patients. Dept-based
  exclusion is applied as a STATUS (computed_status='Excluded') by
  sync_mdm_patient_status, not as a row deletion.

  computed_status / status_reason are written by sync_mdm_patient_status,
  which runs after int_patient_status_computed and merges the canonical
  10-priority active-patient definition back into mdm.reference_data.patient.
  This sync only INSERTs them as NULL on new rows; merge_exclude_columns
  preserves whatever sync_mdm_patient_status last wrote.

  Anti-MERGE cleanup (post_hook): dbt MERGE only inserts/updates, never
  deletes. The post_hook DELETE removes rows whose key has fallen out of
  v_patient_sync (test patients flipped on, NEWPATIENTID merges, hard-
  deleted Athena patients, etc.). Closes the no_filter_drift gap
  automatically. NOTE: dept-10/11 patients (MIDI / Vaccine Clinic) stay
  in MDM (v_patient_sync no longer filters by dept) so EMPI, Salesforce,
  and identity linkage continue to work; they get computed_status =
  'Excluded' via sync_mdm_patient_status because
  int_patient_status_computed filters appointments by is_core_department().
  The exclusion is a status, not a deletion.

  Grain: One row per patient_id
*/

SELECT
    patient_id,
    first_name,
    last_name,
    date_of_birth,
    gender,
    patient_status,
    deleted_yn,
    test_patient_yn,
    salesforce_account_id,
    in_salesforce,
    completed_number,
    future_number,
    cancelled_number,
    total_number,
    golden_id,
    athena_enterprise_id,
    source_system,
    last_updated_at,
    CAST(NULL AS DOUBLE) AS days_since_last_completed_visit,
    CAST(NULL AS TIMESTAMP) AS last_completed_visit_date,
    CAST(NULL AS STRING) AS computed_status,
    CAST(NULL AS STRING) AS status_reason
FROM {{ ref('v_patient_sync') }}
