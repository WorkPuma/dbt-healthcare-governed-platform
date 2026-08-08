{{
    config(
        alias='staff',
        incremental_strategy='merge',
        matched_condition='t.last_updated_at < s.last_updated_at',
        unique_key='staff_email',
        on_schema_change='append_new_columns',
        tags=['mdm', 'sync', 'staff']
    )
}}

/*
  sync_mdm_staff — Incremental MERGE into mdm.reference_data.staff

  MDM Staff is the governed, change-aware roster for Healthcare Org employees
  and contractors. It is the dbt promotion of what was previously assembled
  ad-hoc inside the BackendBaaS mdm_staff view, with the key additions that it:
    - resolves the Athena username crosswalk in dbt (via email join to
      athenahealth.athenaone.userprofile, see int_staff_athena_crosswalk), and
    - retains terminated staff (is_active = false, termination_date set) instead
      of dropping them, so Athena-username-keyed historical attribution (e.g.
      inbox ownership by a since-departed staff member who still has an Athena
      login) resolves. NOTE: Salesforce-keyed attribution for terminated staff
      is NOT covered here — salesforce_id is Entra-sourced (active-only).

  Source: v_staff_sync (Entra/BackendBaaS identity + TriNet HR + Athena crosswalk).

  Grain: One row per staff_email (lowercased work email — the shared join key
  across TriNet work_email, Entra mail, and Athena userprofile email).

  MERGE semantics mirror sync_mdm_provider: rows are updated only when the
  incoming last_updated_at is newer. Rows are never deleted, so a person who
  drops out of all live feeds is retained as a historical record.
*/

select * from {{ ref('v_staff_sync') }}
