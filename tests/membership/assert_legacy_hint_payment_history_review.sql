{{ config(severity='warn', tags=['membership', 'reconciliation']) }}

select
    account_id,
    authority_mismatch_reason
from {{ ref('int_membership_authority') }}
where authority_mismatch_reason = 'legacy_with_membership_paying_history'
