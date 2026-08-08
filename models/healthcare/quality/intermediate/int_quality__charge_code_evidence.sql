-- intermediate — DEV-4296 · int_quality__charge_code_evidence (V3 Databricks dbt)
-- THE VISIT-CHARGE branch of the funnel — billing procedure codes from the charge ledger.
--
-- Chain: visitcharge.VISITID -> clinicalencounter.CLINICALENCOUNTERID (patient_id, encounter date).
-- visitcharge has NO PATIENTID column; patient resolution REQUIRES the encounter join.
-- Proven join pattern from REDACTED_PATH int_quality__encounter_codes.sql Source 4.
--
-- code_type classifier (TWICE V2 pattern, adapted):
--   ^[0-9]{4}[Ff]$ -> CPT_II    (quality-reporting CPT category II)
--   ^[0-9]{4}[Tt]$ -> CPT_III   (CPT category III)
--   ^[0-9]{5}$     -> CPT       (standard 5-digit numeric CPT)
--   ^[A-Z][0-9]{4}$ -> HCPCS   (HCPCS Level II, letter prefix)
--   else            -> UNKNOWN_PROC
--
-- date_of_service CASCADE (funnel invariant — every code row MUST be dated):
--   FROMDATEDATETIME -> encounter_date -> CHARGEDATEDATETIME -> CREATEDDATETIME -> LASTMODIFIEDDATETIME
--
-- evidence_provenance = 'closed_encounter' (tier 2). This is charge-level administrative
-- evidence: codes appear here once the encounter is billed/posted, which is softer than a
-- finalized claim ('billed') but harder than a pending order.
--
-- YEAR-AGNOSTIC: no measurement-year filter here; the pool applies rolling lookback.
-- Deletes: voideddatetime IS NULL and deleteddatetime IS NULL guard soft-deleted rows.

with enc as (
    select
        cast(clinicalencounterid as bigint)                          as clinical_encounter_id,
        cast(cast(patientid as decimal(38,0)) as string)             as patient_id,
        cast(encounterdate as date)                                  as encounter_date
    from athenahealth.athenaone.clinicalencounter
    where deleteddatetime is null
),

vc as (
    select
        cast(visitchargeid as string)                                as visitchargeid,
        cast(visitid as bigint)                                      as visitid,
        cast(procedurecode as string)                                as procedurecode,
        cast(fromdatedatetime as date)                               as fromdatedatetime,
        cast(chargedatedatetime as date)                             as chargedatedatetime,
        cast(createddatetime as date)                                as createddatetime,
        cast(lastmodifieddatetime as date)                           as lastmodifieddatetime
    from athenahealth.athenaone.visitcharge
    where deleteddatetime is null
      and voideddatetime is null
      and procedurecode is not null
),

joined as (
    select
        enc.patient_id,
        vc.visitchargeid,
        vc.procedurecode,
        coalesce(
            vc.fromdatedatetime,
            enc.encounter_date,
            vc.chargedatedatetime,
            vc.createddatetime,
            vc.lastmodifieddatetime
        )                                                            as date_of_service,
        vc.createddatetime                                           as create_date
    from vc
    join enc on enc.clinical_encounter_id = vc.visitid
),

parsed as (
    select
        patient_id,
        split_part(procedurecode, ',', 1)                            as code_base,
        nullif(regexp_extract(procedurecode, '^[^,]*,(.*)$', 1), '') as code_modifier,
        procedurecode                                                as code_raw,
        date_of_service,
        create_date
    from joined
)

select
    patient_id,
    code_base                                                        as code,
    case
        when code_base rlike '^[0-9]{4}[Ff]$'  then 'CPT_II'
        when code_base rlike '^[0-9]{4}[Tt]$'  then 'CPT_III'
        when code_base rlike '^[0-9]{5}$'       then 'CPT'
        when code_base rlike '^[A-Z][0-9]{4}$'  then 'HCPCS'
        else 'UNKNOWN_PROC'
    end                                                              as code_type,
    date_of_service,
    code_raw,
    code_modifier,
    'VISIT_CHARGE'                                                   as source_table,
    year(date_of_service)                                            as measurement_year,
    'system'                                                         as code_origin,
    'visit_charge'                                                   as source_method,
    'closed'                                                         as order_status,
    'closed_encounter'                                               as evidence_provenance,
    create_date
from parsed
where date_of_service is not null
