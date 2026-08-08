{#
  DEV-4296 · int_quality__gap_mirror (V3 Databricks dbt)

  Purpose: patients the QM engine has IDENTIFIED for a measure but that are NOT a confirmed
  coded closure — "possible / assessable closure" — the worklist that feeds HH-added codes.

  This is a QA surface, NEVER a filter. It surfaces open gaps and possible closures so that
  downstream NLP / chart-review processes can supply additional evidence via the code_pool.

  gap_kind taxonomy:
    - 'excluded'          : exclusion_reason is set; patient opted out or clinically excluded.
    - 'possible_closure'  : Needs Data / Out of Range — measure has a signal but no confirmed
                            satisfaction; a newly discovered code might close it.
    - 'open'              : no satisfaction, no exclusion, no useful partial signal.

  gap_source = 'qm_open_gap' for all v1 rows (QM-engine derived).
  Payor-agnostic: no payer filter applied here; downstream sidecars layer on roster.

  Consumers: per-payer "why-not" QA dashboards; NLP/chart-review code-addition worklist.

  TODO v2: cross-reference int_quality__code_pool for measure-relevant codes that exist in the
  pool but are not satisfying the measure (denominator-without-result grain). This would surface
  cases where HH already has the code but the QM engine has not yet processed it — a distinct
  signal from "we don't have the code at all." Not built here; the gap_mirror itself is the
  prerequisite.

  Materialization: view (downstream already incremental; mirror is cheap re-compute on demand).
#}

{{ config(
    materialized    = 'view',
    tags            = ['quality', 'gap-mirror', 'intermediate', 'dev-4296']
) }}

with evidence as (
    select * from {{ ref('int_quality__hedis_evidence') }}
),

gaps as (
    select
        patient_id,
        measure,
        quality_category,
        result_status                                                   as gap_status,
        service_date                                                    as last_signal_date,
        result,
        provider_id,
        program,
        exclusion_reason,
        case
            when exclusion_reason is not null                           then 'excluded'
            when result_status in ('Needs Data', 'Out of Range')       then 'possible_closure'
            else 'open'
        end                                                             as gap_kind,
        'qm_open_gap'                                                   as gap_source
    from evidence
    where coalesce(result_status, '') <> 'SATISFIED'
)

select
    patient_id,
    measure,
    quality_category,
    gap_status,
    gap_kind,
    gap_source,
    last_signal_date,
    result,
    provider_id,
    program,
    exclusion_reason
from gaps
