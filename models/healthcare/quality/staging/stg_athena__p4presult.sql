-- staging (support) — DEV-4296 · stg_athena__p4presult (V3 Databricks dbt)
-- reach: ref('base_athenahealth__p4presult') -> source('athenahealth','p4presult')
--   -> athenahealth.athenaone (Delta). Shared source read (DEV-4296 / PR #346) — the base
--   model is the ONLY reader of the raw table; provider_bonus shares the same base model.
-- thin 1:1. Bridges a QM result -> its measure definition (p4p_measure_id). support only.
-- DROP DELETES: deleteddatetime is null (consumer-specific, kept here).
with source as (
    select
        p4presultid,
        p4pmeasureid,
        deleteddatetime
    from {{ ref('base_athenahealth__p4presult') }}
)
select
    p4presultid                     as p4p_result_id,
    p4pmeasureid                    as p4p_measure_id
from source
where deleteddatetime is null
