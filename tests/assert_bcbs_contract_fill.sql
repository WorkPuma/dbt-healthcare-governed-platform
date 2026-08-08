-- DEV-4296 · assertion: every REQUIRED PAYOR_A contract-output column must be "mostly filled".
-- Catches population regressions in the shipped file (e.g. NPI_NBR silently going 100% -> 0%).
-- Returns one row per column whose non-empty fill rate falls below its threshold -> the test FAILS,
-- naming the column + actual pct so the failure is self-explaining.
--
-- Tiers:
--   * always-required (identity + demographics + coverage + measure key): >= 95% filled
--   * NPI_NBR: >= 95% (payer-specific sidecar enrichment; PCP->provider NPI join has LANDED — populated 2026-07; verified >=95% on the 25,374-row build)
-- Allowlisted EXPECTED-EMPTY columns are deliberately NOT checked (would false-alarm):
--   RACE02-05 (only RACE01 is populated), PREF_ADDR_LN_2_TXT (apt/unit, usually blank),
--   COV_END_DT (blank = open/active coverage), FILE_TRANSFER_DTTM (constant, always present).
-- RESULT / CODE_TYPE / CODE are CONDITIONALLY required per the PAYOR_A measure matrix and are checked
-- by a separate per-measure assertion (not here) to avoid false fails on code-only / value-only measures.

with base as (
    select * from {{ ref('fct_quality__payor_alpha_mn_contract_output') }}
),

n as (
    select count(*) as total from base
),

fills as (
    select 'PATIENTID'          as col, count_if(PATIENTID <> '')          as filled from base
    union all select 'CARE_SYSTEM_NAME',   count_if(CARE_SYSTEM_NAME <> '')   from base
    union all select 'CLINIC_NAME',        count_if(CLINIC_NAME <> '')        from base
    union all select 'NPI_NBR',            count_if(NPI_NBR <> '')            from base
    union all select 'FIRST_NM',           count_if(FIRST_NM <> '')           from base
    union all select 'LAST_NM',            count_if(LAST_NM <> '')            from base
    union all select 'BRTH_DT',            count_if(BRTH_DT <> '')            from base
    union all select 'MBR_ID',             count_if(MBR_ID <> '')             from base
    union all select 'GENDER',             count_if(GENDER <> '')             from base
    union all select 'GRP_NBR',            count_if(GRP_NBR <> '')            from base
    union all select 'RACE01',             count_if(RACE01 <> '')             from base
    union all select 'PREF_LANG',          count_if(PREF_LANG <> '')          from base
    union all select 'PREF_ADDR_LN_1_TXT', count_if(PREF_ADDR_LN_1_TXT <> '') from base
    union all select 'PREF_CITY_NM',       count_if(PREF_CITY_NM <> '')       from base
    union all select 'PREF_STPRV_CD',      count_if(PREF_STPRV_CD <> '')      from base
    union all select 'PREF_ZIP_CD',        count_if(PREF_ZIP_CD <> '')        from base
    union all select 'COV_STRT_DT',        count_if(COV_STRT_DT <> '')        from base
    union all select 'DATE_OF_SERVICE',    count_if(DATE_OF_SERVICE <> '')    from base
    union all select 'MEASURE_TYPE',       count_if(MEASURE_TYPE <> '')       from base
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
