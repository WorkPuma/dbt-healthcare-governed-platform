/*
  DEV-4535: xref.identity_id must never point at a MERGED registry row.
  Matching should resolve/rewrite absorbed xrefs to the survivor H-#.
*/

{{ config(severity='error', tags=['empi', 'identity', 'integrity']) }}

select
    x.source_system,
    x.source_id,
    x.identity_id,
    r.status,
    r.merged_into_identity_id
from {{ source('healthcare', 'empi_identity_xref') }} x
inner join {{ source('healthcare', 'empi_identity_registry') }} r
    on r.identity_id = x.identity_id
where r.status = 'MERGED'
