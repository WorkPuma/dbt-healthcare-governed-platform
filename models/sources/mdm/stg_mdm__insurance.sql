{{
    config(
        tags=['mdm', 'insurance', 'reference']
    )
}}

with source as (
    select * from {{ ref('sync_mdm_insurance') }}
),

insurance as (
    select
        -- Primary Keys
        insurance_package_id,

        -- Insurance Info
        insurance_package_name,
        insurance_product_type_id,
        insurance_product_type,
        payer_name,
        insurance_reporting_category,
        insurance_type,

        -- MDM Classification
        irc_group,
        coalesce(
            government_funded_type,
            case when Government_Insurance = 'true' then 'Federal' end
        ) as government_funded_type,
        Government_Insurance as government_insurance,

        -- X12 270/271 payer identifier (Athena EMCCODE). Joins back to a 271
        -- response via payer.payorIdentification when reverse-resolving a
        -- EligibilityAPI eligibility check to an Athena insurance_package_id.
        edi_payer_id,

        -- Status
        status,
        deleted_yn,

        -- Metrics
        patient_insurance_count,

        -- Metadata
        source_system,
        last_updated_at

    from source
    where deleted_yn = 'N'
)

select * from insurance
