-- staging (support) — DEV-4296 · stg_athena__p4pmeasure (V3 Databricks dbt)
-- reach: ref('base_athenahealth__p4pmeasure') -> source('athenahealth','p4pmeasure')
--   -> athenahealth.athenaone (Delta). Shared source read (DEV-4296 / PR #346) — the base
--   model is the ONLY reader of the raw table; provider_bonus shares the same base model.
-- thin 1:1. Measure definition: category (HEDIS bucket) + measure type. support only.
-- DROP DELETES: deleteddatetime is null (consumer-specific, kept here).
with source as (
    select
        p4pmeasureid,
        category,
        shortname,
        measuretype,
        deleteddatetime
    from {{ ref('base_athenahealth__p4pmeasure') }}
)
select
    p4pmeasureid                    as p4p_measure_id,
    category                        as category,
    shortname                       as short_name,
    measuretype                     as measure_type
from source
where deleteddatetime is null
