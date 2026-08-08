{{
    config(
        tags=['mdm', 'staff', 'reference']
    )
}}

/*
  stg_mdm__staff — MDM Staff staging (thin pass-through)

  Reads from the governed MDM staff table (sync_mdm_staff), the single source
  of truth for the Healthcare Org roster: identity + org (Entra), employment
  (TriNet HRIS), and the Athena username crosswalk (resolved by email).

  Reads ref('sync_mdm_staff') directly (not source('mdm','staff')) so the DAG
  is self-contained and does not require the physical mdm.reference_data.staff
  table to pre-exist in the dev deep-clone.

  NOTE: is_active is NOT filtered here — terminated staff are retained (with
  is_active = false, termination_date set) so historical attribution resolves.
  Downstream models decide whether to include terminated staff.
*/

select
    staff_email,

    -- Cross-system identifiers
    mdm_staff_id,
    entra_id,
    trinet_employee_id,
    salesforce_id,
    athena_user_id_mdm,

    -- Athena username crosswalk (dbt-resolved via email)
    primary_athena_username,
    primary_athena_userprofile_id,
    athena_usernames,
    athena_userprofile_ids,

    -- Identity / org
    full_name,
    job_title,
    department,
    manager,
    manager_email,
    role,
    team,
    org_group,
    account_type,
    office_location,

    -- Employment
    hire_date,
    start_date,
    termination_date,
    trinet_employee_status,
    fte,
    employment_type,
    trinet_company_id,

    -- Presence / status flags
    in_entra,
    in_trinet,
    has_athena_login,
    is_pre_hire,
    is_active,

    -- Metadata
    source_system,
    last_updated_at

from {{ ref('sync_mdm_staff') }}
