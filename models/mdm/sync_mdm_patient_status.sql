{{
    config(
        materialized='view',
        database='databricks_prod',
        schema='staging',
        tags=['mdm', 'sync', 'patient', 'status'],
        post_hook=[
            "MERGE INTO mdm.reference_data.patient t USING {{ this }} s ON t.patient_id = s.patient_id WHEN MATCHED AND (coalesce(t.computed_status, '') != coalesce(s.computed_status, '') OR coalesce(t.status_reason, '') != coalesce(s.status_reason, '')) THEN UPDATE SET t.computed_status = s.computed_status, t.status_reason = s.status_reason, t.last_updated_at = current_timestamp()"
        ]
    )
}}

/*
  sync_mdm_patient_status — Aligns mdm.reference_data.patient.{computed_status,
  status_reason} with the canonical active-patient definition.

  Architecture:

    sync_mdm_patient        (writes mdm.reference_data.patient — demographics,
                             SF link, EMPI; computed_status/status_reason NULL)
        |
        v
    stg_mdm__patient        (view; reads sync_mdm_patient)
        |
        v
    int_patient_status_computed
        (canonical 10-priority logic: Deceased > Deleted > Re-Engaging >
         Prospect > New Lead > Excluded > 18-mo-inactive > Athena 'i' >
         Active > fallback. See model header for full priority order.)
        |
        v
    sync_mdm_patient_status (THIS MODEL — post_hook MERGE writes
                             computed_status/status_reason back into
                             mdm.reference_data.patient)

  The model itself materializes as a thin staging view that exposes the
  computed status per patient. The post_hook does the actual write back into
  the MDM patient table via UPDATE-only MERGE.

  Why split this from sync_mdm_patient?
    int_patient_status_computed depends transitively on sync_mdm_patient
    (via stg_mdm__patient), so we cannot compute the status inside the same
    model that produces the patient roster — that would be a DAG cycle.

  post_hook MERGE behavior:
    UPDATE-only — every patient_id is guaranteed to exist in
    mdm.reference_data.patient because sync_mdm_patient runs earlier in
    the DAG (this model refs int_patient_status_computed which transitively
    refs sync_mdm_patient). The MATCHED guard skips no-op updates by
    comparing both columns with COALESCE-against-empty-string sentinel,
    so Delta CDF only records rows whose canonical status actually changed.

  Grain: One row per patient_id.
*/

select
    patient_id,
    computed_status,
    status_reason
from {{ ref('int_patient_status_computed') }}
where computed_status is not null
