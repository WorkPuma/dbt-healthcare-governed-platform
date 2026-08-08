{{ config(severity='error', tags=['membership', 'balance']) }}

select
    account_id,
    is_legacy_routed,
    is_legacy_active,
    authority_mismatch_reason
from {{ ref('int_membership_authority') }}
where authority_mismatch_reason in (
    'routed_missing_backendbaas',
    'backendbaas_active_not_routed',
    'routed_not_active_in_backendbaas'
)
