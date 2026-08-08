{{
    config(
        alias='appointment_type',
        incremental_strategy='merge',
        unique_key='appointment_type_id',
        on_schema_change='ignore',
        matched_condition='t.last_updated_at < s.last_updated_at',
        merge_exclude_columns=['AWV_Visit', 'Patient_Visit', 'Telehealth_Visit',
                               'Behavioral_Health_Visit', 'Ancillary_Visit',
                               'Initial_Visit', 'Routine_Visit',
                               'Non_Provider', 'review_status'],
        tags=['mdm', 'sync', 'appointment_type']
    )
}}

/*
  sync_mdm_appointment_type — Incremental MERGE into mdm.reference_data.appointment_type

  Replaces the standalone MDM Appointment Type Daily Refresh job.
  Preserves hand-curated classification flags (AWV_Visit, Patient_Visit, etc.)
  via merge_exclude_columns — those columns are only set during INSERT (new types)
  and never overwritten by the sync.

  Source: Athena appointmenttype joined with appointment counts

  Grain: One row per appointment_type_id
*/

SELECT
    CAST(src.APPOINTMENTTYPEID AS BIGINT) AS appointment_type_id,
    CAST(src.CONTEXTID AS BIGINT) AS context_id,
    CAST(NULL AS BIGINT) AS department_id,
    src.APPOINTMENTTYPENAME AS appointment_type_name,
    COALESCE(dim.APPOINTMENTTYPESHORTNAME, '') AS appointment_type_short_name,
    src.APPOINTMENTTYPECLASS AS description,
    CAST(src.DURATION AS INT) AS duration,
    CASE WHEN src.GENERICYN = 'Y' THEN 'Y' ELSE 'N' END AS web_schedulable_yn,
    'Y' AS patient_yn,
    CASE WHEN src.DELETEDDATETIME IS NOT NULL THEN 'Y' ELSE 'N' END AS deleted_yn,
    COALESCE(appt_counts.appointment_count, 0) AS appointment_count,
    'Athena' AS source_system,
    src.lastupdated AS last_updated_at,
    CAST(NULL AS BOOLEAN) AS AWV_Visit,
    CAST(NULL AS BOOLEAN) AS Patient_Visit,
    CAST(NULL AS BOOLEAN) AS Telehealth_Visit,
    CAST(NULL AS BOOLEAN) AS Behavioral_Health_Visit,
    CAST(NULL AS BOOLEAN) AS Ancillary_Visit,
    CAST(NULL AS BOOLEAN) AS Initial_Visit,
    CAST(NULL AS BOOLEAN) AS Routine_Visit,
    CAST(NULL AS BOOLEAN) AS Non_Provider,
    CAST(NULL AS STRING) AS review_status
FROM {{ source('athenahealth', 'appointmenttype') }} src
LEFT JOIN `Healthcare`.`org_dmart`.`dim_appointmenttypeduration` dim
    ON src.APPOINTMENTTYPEID = dim.APPOINTMENTTYPEID
LEFT JOIN (
    SELECT
        APPOINTMENTTYPEID AS appt_type_id,
        COUNT(*) AS appointment_count
    FROM {{ source('athenahealth', 'appointment') }}
    GROUP BY APPOINTMENTTYPEID
) appt_counts
    ON src.APPOINTMENTTYPEID = appt_counts.appt_type_id
{% if is_incremental() %}
WHERE src.lastupdated >= (
    SELECT DATEADD(HOUR, -24, COALESCE(MAX(last_updated_at), TIMESTAMP '1900-01-01'))
    FROM {{ this }}
)
{% endif %}
