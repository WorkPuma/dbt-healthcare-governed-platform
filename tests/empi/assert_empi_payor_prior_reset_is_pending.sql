/*
  DEV-4545: target-change resets must leave rows pending with a prior:* reason.
  When an approved match's golden/athena target changes, MERGE sets
  approval_status='pending' and rejection_reason=concat('prior:', <old status>).
*/

{{ config(severity='error', tags=['empi', 'identity', 'integrity', 'payor']) }}

select
    match_id,
    payor,
    payor_member_id,
    approval_status,
    rejection_reason,
    golden_id,
    athena_patient_id
from {{ source('healthcare', 'empi_payor_matches') }}
where rejection_reason like 'prior:%'
  and approval_status <> 'pending'
