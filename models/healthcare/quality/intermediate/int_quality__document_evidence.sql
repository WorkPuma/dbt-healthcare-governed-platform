-- intermediate — DEV-4296 · int_quality__document_evidence (the REFERRAL-OUT / DOCUMENT branch)
-- THE missing funnel capture branch. Externally-performed results return to athena as signed-off
-- DOCUMENTS, never as an HH charge/encounter/claim: a mammogram done at an imaging center, a
-- colonoscopy / CT colonography, an external pap, a diabetic eye exam, an external kidney lab. The
-- in-house branches (charge/encounter/claim/lab/service) STRUCTURALLY cannot see these — the patient
-- was referred OUT, so the only trace is a result DOCUMENT. This is why BCS/COL/CCS/EED/UACR silently
-- under-captured — evidence lived in `document` that no other branch read.
-- Ported from REDACTED_PATH int_quality__hedis_evidence.sql bcs_matched / col_matched /
-- eed_matched / uacr (Q27-compliant: athena's OWN clinicalordertypecpt table resolves the CPT — NO
-- pattern-matching, NO inference, NO fabrication).
--
-- PAYER-AGNOSTIC (funnel law): captures EVERY document CPT — no measure filter, no accepted-code
-- filter, no measurement-year filter here. Per-measure accepted-code filtering + HEDIS lookback live
-- DOWNSTREAM (measure_dated / the payer sidecar). The only gates are CLINICAL-QUALITY, not payer:
-- documentclass in (IMAGINGRESULT, LABRESULT, CLINICALDOCUMENT) = the result-bearing classes, and
-- status = 'CLOSED' = provider signed off (the screening/result is finalized, not a draft).
--
-- CPT RESOLUTION folds in the `clinicalresult` surface via a dual path: (via_document) the document's
-- OWN clinicalordertypeid -> clinicalordertypecpt for imaging results; (via_result) for result-bearing
-- docs that carry no order-type, the linked clinicalresult row's clinicalordertypeid -> cpt for
-- external lab results. date_of_service = coalesce(observationdatetime, createddatetime) — when the
-- screening occurred; created fallback covers scribe-blank obs (OLD's NULL-obs fix).
-- evidence_provenance = 'resulted' (a signed-off referral-out result: harder than a pending order,
-- softer than an in-house claim). order_status 'closed' mirrors the charge branch.

with doc as (
    select
        cast(cast(patientid as decimal(38,0)) as string)                  as patient_id,
        cast(documentid as string)                                        as document_id,
        cast(clinicalordertypeid as bigint)                               as doc_order_type_id,
        documentclass                                                     as document_class,
        coalesce(cast(observationdatetime as date), cast(createddatetime as date)) as date_of_service,
        cast(createddatetime as date)                                     as create_date
    from athenahealth.athenaone.document
    where deleteddatetime is null
      and status = 'CLOSED'
      and documentclass in ('IMAGINGRESULT', 'LABRESULT', 'CLINICALDOCUMENT')
),

cres as (
    select
        cast(documentid as string)                                        as document_id,
        cast(clinicalordertypeid as bigint)                               as res_order_type_id
    from athenahealth.athenaone.clinicalresult
    where clinicalordertypeid is not null
),

cotc as (
    select
        cast(clinicalordertypeid as bigint)                               as clinical_order_type_id,
        cast(procedurecode as string)                                     as procedurecode
    from athenahealth.athenaone.clinicalordertypecpt
    where deleteddatetime is null
      and procedurecode is not null
),

via_document as (
    select d.patient_id, c.procedurecode, d.document_class, d.date_of_service, d.create_date
    from doc d
    join cotc c on d.doc_order_type_id = c.clinical_order_type_id
    where d.doc_order_type_id is not null
),

via_result as (
    select d.patient_id, c.procedurecode, d.document_class, d.date_of_service, d.create_date
    from doc d
    join cres r on d.document_id = r.document_id
    join cotc c on r.res_order_type_id = c.clinical_order_type_id
    where d.doc_order_type_id is null
),

joined as (
    select * from via_document
    union all
    select * from via_result
)

select
    patient_id,
    procedurecode                                                         as code,
    case
        when procedurecode rlike '^[0-9]{4}[Ff]$'  then 'CPT_II'
        when procedurecode rlike '^[0-9]{4}[Tt]$'  then 'CPT_III'
        when procedurecode rlike '^[0-9]{5}$'       then 'CPT'
        when procedurecode rlike '^[A-Z][0-9]{4}$'  then 'HCPCS'
        else 'UNKNOWN_PROC'
    end                                                                   as code_type,
    date_of_service,
    procedurecode                                                         as code_raw,
    cast(null as string)                                                  as code_modifier,
    'DOCUMENT_RESULT'                                                      as source_table,
    year(date_of_service)                                                 as measurement_year,
    'system'                                                               as code_origin,
    lower(document_class)                                                  as source_method,
    'closed'                                                               as order_status,
    'resulted'                                                             as evidence_provenance,
    create_date
from joined
where date_of_service is not null
  and patient_id is not null
