/*
  DEV-4545: payor identity spine golden_id must match registry.current_golden_id
  for the resolved identity. Consumers must not ship stale denormalized goldens.
  FULL OUTER so spine rows missing a registry match also fail.
*/

{{ config(severity='error', tags=['empi', 'identity', 'integrity']) }}

select
    s.payor,
    s.payor_member_id,
    coalesce(s.identity_id, r.identity_id) as identity_id,
    s.golden_id as spine_golden_id,
    r.current_golden_id
from {{ ref('int_empi__payor_identity_spine') }} s
full outer join {{ source('healthcare', 'empi_identity_registry') }} r
    on r.identity_id = s.identity_id
where s.identity_id is not null
  and (
      r.identity_id is null
      or s.golden_id is distinct from r.current_golden_id
  )
