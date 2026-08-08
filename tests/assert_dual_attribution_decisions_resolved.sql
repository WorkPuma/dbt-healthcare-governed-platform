/*
  Eligibility-decision attributions must be internally consistent:
    1. A decided dual-attribution patient must have a primary payor set.
    2. The chosen primary payor must actually be in the patient's live
       attributed payor set (guards against stale/malformed decisions naming a
       payor that no longer attributes the patient).
  Pending dual patients (no valid decision yet) are excluded.
*/

{{ config(severity='error', tags=['attribution', 'canonical', 'dual_attribution']) }}

select
    patient_id,
    payor_attribution_count,
    attribution_source,
    payor_attributed_list,
    primary_attribution_payor
from {{ ref('int_attribution_payor_slots') }}
where attribution_source = 'eligibility_decision'
  and (
        primary_attribution_payor is null
        or not array_contains(split(payor_attributed_list, ', '), primary_attribution_payor)
  )
