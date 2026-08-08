{{ config(materialized='table') }}

-- intermediate — DEV-4296 · int_quality__code_titles (V3 Databricks dbt)
-- THE CANONICAL CODE -> TITLE LAYER — every code flowing through the funnel gets a proper title, so
-- measure matching can anchor on (code + title) instead of brittle category equality. Both recent
-- evidence-loss bugs were category/string-exact failures: PHQ9 died on a code_list string ('[Reported]'
-- suffix), MedList died on a code_type category (CPT_II vs CPT). The code is the stable identifier; the
-- title is the semantic anchor; the category is metadata, never a match gate.
--
-- This dim is the FOUNDATION for code+title matching (later: Levenshtein/vector similarity with a
-- confidence score, low-confidence -> QA surface). It is keyed on the DISTINCT codes actually present
-- in int_quality__code_pool (the funnel universe), so a coverage audit immediately shows where titles
-- are missing.
--
-- Title sources (best authority per system):
--   * clinical_title  <- athenahealth.athenaone.icdcodeall.diagnosiscodedescription (ICD, dotless,
--                        matches the pool's dotless ICDs). Authoritative clinical descriptor.
--   * value_set_titles <- ref_payor_alpha_accepted_codes.code_list (the HEDIS value-set name every accepted
--                        code carries; for LOINC this IS the LOINC long name). Covers the codes that
--                        actually participate in measure matching, across ALL code systems.
--   CPT_II/CPT_III are normalized to CPT for the value-set lookup (same fix as the MedList join), so a
--   precise CPT-II classification never hides a code from its value set.
--
-- normalized_title strips a trailing bracketed qualifier (e.g. ' [Reported]', ' [Presence]') and lower/
-- trims — the canonical form for fuzzy reconciliation. title_source flags coverage: athena_icd /
-- athena_cpt / athena_snomed / athena_loinc / value_set / untitled. 'untitled' rows (non-ICD,
-- non-value-set codes) are the residual gap.
--
-- Reference-table resolution: icdcodeall and procedurecodereference are native in athenahealth
-- (Databricks replica) and read directly / via source(). snomed and loinc have NO native replica yet —
-- they are resolved via athena_ref() (macros/athena_ref.sql), which prefers athenahealth.<schema>.<table>
-- and falls back to the athena.<schema>.<table> Snowflake federation, logging every fallback so the gap
-- can be requested for native replication.

with pool_codes as (
    select distinct code, code_type as code_system
    from {{ ref('int_quality__code_pool') }}
),

value_set_titles as (
    select
        code,
        code_system,
        array_distinct(collect_list(code_list)) as value_set_titles
    from {{ ref('ref_payor_alpha_accepted_codes') }}
    group by code, code_system
),

icd_titles as (
    select
        diagnosiscode                       as code,
        max(diagnosiscodedescription)       as clinical_title
    from {{ athena_ref('athenaone', 'icdcodeall') }}
    where diagnosiscodedescription is not null
    group by diagnosiscode
),

cpt_hcpcs_titles as (
    select
        upper(trim(procedurecode))                                          as code,
        max(coalesce(nullif(trim(description), ''), nullif(trim(commondescription), ''))) as cpt_title
    from {{ source('athenahealth', 'procedurecodereference') }}
    where procedurecode is not null and trim(procedurecode) <> ''
      and deleteddatetime is null
      and coalesce(lower(trim(isdeletedcode)), 'false') not in ('true', 'y', '1', 't')
      and coalesce(nullif(trim(description), ''), nullif(trim(commondescription), '')) is not null
    group by upper(trim(procedurecode))
),

snomed_titles as (
    select
        cast(snomedcode as string)                 as code,
        max(description)                            as snomed_title
    from {{ athena_ref('athenaone', 'snomed') }}
    where description is not null
      and coalesce(lower(trim(cast(isdeleted as string))), 'false') not in ('true', 'y', '1', 't')
    group by cast(snomedcode as string)
),

loinc_titles as (
    select
        upper(trim(loinccode))                      as code,
        max(longcommonname)                         as loinc_title
    from {{ athena_ref('athenaone', 'loinc') }}
    where longcommonname is not null
      and coalesce(lower(trim(cast(isdeleted as string))), 'false') not in ('true', 'y', '1', 't')
    group by upper(trim(loinccode))
)

select
    p.code,
    p.code_system,
    vt.value_set_titles,
    it.clinical_title,
    ct.cpt_title,
    sn.snomed_title,
    ln.loinc_title,
    coalesce(it.clinical_title, ct.cpt_title, sn.snomed_title, ln.loinc_title, element_at(vt.value_set_titles, 1))  as canonical_title,
    lower(trim(regexp_replace(
        coalesce(it.clinical_title, ct.cpt_title, sn.snomed_title, ln.loinc_title, element_at(vt.value_set_titles, 1), ''),
        '\\s*\\[[^\\]]*\\]\\s*$', ''
    )))                                                                  as normalized_title,
    case
        when it.clinical_title is not null    then 'athena_icd'
        when ct.cpt_title is not null         then 'athena_cpt'
        when sn.snomed_title is not null      then 'athena_snomed'
        when ln.loinc_title is not null       then 'athena_loinc'
        when vt.value_set_titles is not null  then 'value_set'
        else 'untitled'
    end                                                                  as title_source
from pool_codes p
left join value_set_titles vt
    on p.code = vt.code
   and (case when p.code_system in ('CPT_II', 'CPT_III') then 'CPT' else p.code_system end) = vt.code_system
left join icd_titles it
    on p.code = it.code and p.code_system = 'ICD10CM'
left join cpt_hcpcs_titles ct
    on upper(trim(p.code)) = ct.code
   and p.code_system in ('CPT', 'CPT_II', 'CPT_III', 'HCPCS')
left join snomed_titles sn
    on cast(p.code as string) = sn.code and p.code_system = 'SNOMED'
left join loinc_titles ln
    on upper(trim(p.code)) = ln.code and p.code_system = 'LOINC'
