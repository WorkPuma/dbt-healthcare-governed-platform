{{ config(severity='error', tags=['membership', 'balance']) }}

select lm.account_id
from {{ ref('stg_backendbaas__legacy_members') }} lm
left join {{ source('salesforce', 'account') }} a
    on lm.account_id = cast(a.id as string)
   and a.isdeleted = false
   and a.__end_at is null
where a.id is null
