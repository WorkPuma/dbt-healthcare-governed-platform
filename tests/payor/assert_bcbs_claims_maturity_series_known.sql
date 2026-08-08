/*
  Macro fixture test for payor_alpha_claims_maturity_series / payor_alpha_claims_maturity_tier.

  Covers with_runout, no_runout, unspecified, null input, and precedence when
  both no-runout and runout tokens appear (no_runout wins — checked first).
  Returns rows when series or tier would classify incorrectly.
*/

{{ config(severity='error') }}

with fixtures as (
    select stack(
        12,
        'PAYOR_ALPHAMN.Herself_Health.2025.MedAdv.HVN. (FY 2025 Members & Claims through June 25 - 2MRO).xlsx', 'with_runout', 0,
        'PAYOR_ALPHAMN.Herself_Health.2025.MedAdv.HVN. (FY 2025 Members & Claims through June 25 - No Runout).xlsx', 'no_runout', 2,
        'PAYOR_ALPHAMN.Herself_Health.2024.MedAdv.HVN.mbrnro. (Claims through May 24 - No Runout).xlsx', 'no_runout', 2,
        'PAYOR_ALPHAMN.HERSELF_HEALTH.2024.MedAdv.HVN.Claims8mro.082025.txt', 'with_runout', 0,
        '02.2026 rolling 12m Claims no runout.xlsx', 'no_runout', 2,
        'PAYOR_ALPHAMN.Herself_Health.2025.MedAdv.HVN. (FY 2025 Members & Claims through Mar 25, 2 Months Runout).xlsx', 'with_runout', 0,
        'PAYOR_ALPHAMN.Herself_Health.2025.MedAdv.HVN. (FY 2025 Members & Claims through June 25).xlsx', 'unspecified', 1,
        cast(null as string), 'unspecified', 1,
        'Claims through June 25 - No Runout with 2MRO.xlsx', 'no_runout', 2,
        'PAYOR_ALPHAMN.Herself_Health.Claims.NRO.202506.txt', 'no_runout', 2,
        'PAYOR_ALPHAMN.Herself_Health.2025.MedAdv.HVN_mbrnro_claims.xlsx', 'no_runout', 2,
        'PAYOR_ALPHAMN.Herself_Health.2025.MedAdv.HVN_nro_extract.xlsx', 'no_runout', 2
    ) as (source_filename, expected_series, expected_tier)
),

classified as (
    select
        source_filename,
        expected_series,
        expected_tier,
        {{ payor_alpha_claims_maturity_series('source_filename') }} as actual_series,
        {{ payor_alpha_claims_maturity_tier('source_filename') }} as actual_tier
    from fixtures
)

select
    source_filename,
    expected_series,
    actual_series,
    expected_tier,
    actual_tier
from classified
where not (actual_series <=> expected_series)
   or not (actual_tier <=> expected_tier)
