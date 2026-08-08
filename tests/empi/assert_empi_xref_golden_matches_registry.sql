/*
  DEV-4545: warn while ACTIVE xref.golden_id lags registry.current_golden_id.
  Spine/marts resolve via registry; this tracks denormalized cache debt until
  an approved xref backfill (or notebook sync) clears it.
  Scoped to ACTIVE + non-null current_golden to match Splink sync / backfill.
*/

{{ config(severity='warn', tags=['empi', 'identity', 'integrity']) }}

select
    x.source_system,
    x.source_id,
    coalesce(x.identity_id, r.identity_id) as identity_id,
    x.golden_id as xref_golden_id,
    r.current_golden_id
from {{ source('healthcare', 'empi_identity_xref') }} x
full outer join {{ source('healthcare', 'empi_identity_registry') }} r
    on r.identity_id = x.identity_id
where
    (
        x.identity_id is not null
        and r.status = 'ACTIVE'
        and r.current_golden_id is not null
        and x.golden_id is distinct from r.current_golden_id
    )
    or (
        -- xref pointing at missing registry row
        x.identity_id is not null
        and r.identity_id is null
    )
