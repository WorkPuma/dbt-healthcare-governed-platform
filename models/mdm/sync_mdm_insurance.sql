{{
    config(
        alias='insurance',
        incremental_strategy='merge',
        matched_condition='t.last_updated_at < s.last_updated_at',
        unique_key='insurance_package_id',
        on_schema_change='ignore',
        merge_exclude_columns=['experian_payer_code', 'experian_payer_name',
                               'review_status'],
        tags=['mdm', 'sync', 'insurance']
    )
}}

/*
  sync_mdm_insurance — Incremental MERGE into mdm.reference_data.insurance

  Replaces the standalone MDM Insurance Sync job.
  Preserves Government_Insurance when the source value is NULL (COALESCE).
  Derives government_funded_type = 'Federal' when Government_Insurance is true
  but Athena has no government type (e.g. FEHB/FEP plans).

  Medigap guard: Medicare Supplemental Plans are private insurance products
  funded by patient premiums, NOT government. The only valid exception is
  TRICARE For Life (DoD-funded). Strip Government_Insurance for all other
  Medigap packages to prevent false-positive propagation via COALESCE.

  Source: mdm.reference_data.v_insurance_sync

  Grain: One row per insurance_package_id
*/

WITH source AS (
    SELECT
        s.*,
        s.insurance_product_type = 'Medicare Supplemental Plan'
            AND COALESCE(s.government_funded_type, 'NONE') NOT IN ('TRICARE', 'CHAMPVA')
            AS _is_private_medigap
    FROM {{ source('mdm', 'v_insurance_sync') }} s
)

SELECT
    source.insurance_package_id,
    source.insurance_package_name,
    source.insurance_product_type_id,
    source.insurance_product_type,
    source.payer_name,
    source.insurance_reporting_category,
    source.insurance_type,
    source.status,
    source.deleted_yn,
    source.patient_insurance_count,
    source.source_system,
    source.last_updated_at,
    source.irc_group,
    -- X12 270/271 payer identifier (Athena EMCCODE). Used by EligibilityAPI as
    -- payer.payorIdentification on the 271 response. Many Athena packages
    -- share the same edi_payer_id (e.g. all PAYOR_A-MN packages share '00720');
    -- consumers disambiguate by insurance_product_type when matching back.
    source.edi_payer_id,
    {% if is_incremental() %}
    CASE
        WHEN source._is_private_medigap THEN NULL
        ELSE COALESCE(
            source.government_funded_type,
            CASE WHEN COALESCE(source.Government_Insurance, existing.Government_Insurance) = 'true' THEN 'Federal' END,
            existing.government_funded_type
        )
    END AS government_funded_type,
    CASE
        WHEN source._is_private_medigap THEN NULL
        ELSE COALESCE(source.Government_Insurance, existing.Government_Insurance)
    END AS Government_Insurance
    {% else %}
    CASE
        WHEN source._is_private_medigap THEN NULL
        ELSE COALESCE(
            source.government_funded_type,
            CASE WHEN source.Government_Insurance = 'true' THEN 'Federal' END
        )
    END AS government_funded_type,
    CASE
        WHEN source._is_private_medigap THEN NULL
        ELSE source.Government_Insurance
    END AS Government_Insurance
    {% endif %},
    CAST(NULL AS STRING) AS experian_payer_code,
    CAST(NULL AS STRING) AS experian_payer_name,
    CAST(NULL AS STRING) AS review_status
FROM source
{% if is_incremental() %}
LEFT JOIN {{ this }} existing
    ON source.insurance_package_id = existing.insurance_package_id
{% endif %}
