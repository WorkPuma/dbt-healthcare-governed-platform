/*
  Test: CMS-paid RAF plausibility — WARN

  An average-risk MA member has RAF ~ 1.0; capitation scales ~linearly with it.
  Values outside [0.1, 4.0] are suspect (RAF = 0 usually means not-yet-scored or
  a parse miss; RAF > 4 is rare but legitimately occurs for ESRD/hospice), so
  this is WARN, not ERROR — it's a data-quality signal, not an arithmetic
  invariant. Helps explain the low PAYOR_A average RAF (null/zero RAF on ghost rows).

  Only inspects rows where cms_paid_raf is populated.
*/

{{ config(severity='warn', tags=['spend', 'finance', 'raf', 'plausibility']) }}

select
    payor,
    -- redact: opaque md5 surrogate, not the raw patient id, so test/failure
    -- artifacts carry no PHI. Rejoin to the fact via md5(cast(patient_id as string)).
    md5(cast(patient_id as string))                  as patient_key,
    service_month,
    cms_paid_raf,
    'cms_paid_raf outside plausible [0.1, 4.0]'       as warning_reason
from {{ ref('fct_spend__patient_month') }}
where cms_paid_raf is not null
  and (cms_paid_raf < 0.1 or cms_paid_raf > 4.0)
