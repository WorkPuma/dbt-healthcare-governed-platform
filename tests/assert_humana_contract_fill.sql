-- DEV-4296 · assertion: every REQUIRED PAYOR_C contract-output column must be "mostly filled".
-- PAYOR_C equivalent of assert_payor_alpha_contract_fill (PR #346 #5.3): catches population regressions in
-- the shipped 49-column file (e.g. rendering_provider_npi silently going 100% -> 0%). Returns one row
-- per column whose non-empty fill rate falls below its threshold -> the test FAILS, naming the column
-- + actual pct so the failure is self-explaining.
--
-- Tier: always-required (identity + demographics + rendering NPI + service date): >= 95% filled.
--   member_card_id + service_date are structurally guaranteed (member_card_id gate excludes unfileable
--   rows upstream; service_date is not_null). first/last/dob/gender come from the demographics mart.
--   rendering_provider_npi rides the same PCP->provider NPI join as PAYOR_A (verified >=95% there).
--   NOTE: PAYOR_C fill rates are pending first-build verification (local compile is warehouse-gated);
--   if the PAYOR_C A_ONLY (EMPI-carded) cohort lacks PCP NPIs the 95% NPI threshold may need tuning,
--   exactly as the PAYOR_A NPI threshold was verified against its first build.
-- Allowlisted EXPECTED-EMPTY / CONDITIONAL columns are deliberately NOT checked (would false-alarm):
--   member_ssn (intentionally BLANK — PHI, never stored), member_medicare_id / member_medicaid_id
--   (optional, spec 'N'), all code slots (icd_diagnosis_code_*, procedural_icd_code_*, cpt_*, loinc_*,
--   bp_*, ndc/snomed/pot/cvx/rx_norm/revenue_code/icd_version — conditionally populated per measure &
--   code-type, checked by the per-measure assertion, not here), v1-blank slots (bmi_value, member_weight,
--   prov_rec_id, discharge_status_code), and QA-only columns (measures_served, evidence_provenance,
--   measurement_year).

with base as (
    select * from {{ ref('fct_quality__payor_gamma_contract_output') }}
),

n as (
    select count(*) as total from base
),

fills as (
    select 'member_card_id'          as col, count_if(member_card_id <> '')          as filled from base
    union all select 'member_first_name',     count_if(member_first_name <> '')       from base
    union all select 'member_last_name',      count_if(member_last_name <> '')        from base
    union all select 'member_dob',            count_if(member_dob <> '')              from base
    union all select 'member_gender',         count_if(member_gender <> '')           from base
    union all select 'rendering_provider_npi', count_if(rendering_provider_npi <> '') from base
    union all select 'service_date',          count_if(service_date <> '')            from base
)

select
    f.col,
    f.filled,
    n.total,
    round(100.0 * f.filled / n.total, 1) as fill_pct,
    95 as min_pct
from fills f
cross join n
where 100.0 * f.filled / n.total < 95
