/*
  DEV-4535: must-not-link pairs are stored in canonical order (a < b).
*/

{{ config(severity='error', tags=['empi', 'identity', 'integrity']) }}

select
    identity_id_a,
    identity_id_b,
    reason,
    request_id
from {{ source('healthcare', 'empi_identity_must_not_link') }}
where identity_id_a is null
   or identity_id_b is null
   or identity_id_a >= identity_id_b
