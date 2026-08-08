{{
    config(
        tags=['athenahealth', 'p4presultdata', 'base']
    )
}}

/*
    Base passthrough for the raw athenahealth.athenaone.P4PRESULTDATA Delta
    table.

    This is the ONLY model that reads the raw P4PRESULTDATA source. Pure 1:1
    passthrough -- no filter, no rename -- shared by BOTH the quality funnel
    (stg_athena__p4presultdata, which drops deleteddatetime is not null and
    renames key/value) and provider_bonus (stg_bonus__quality_measures,
    inline reader).

    Per DEV-4296 shared-staging decision (PR #346 review, Data Engineer): one
    shared source read, consumer-specific filters/renames stay downstream.
    See REDACTED_PATH
*/

select
    p4presultid,
    key,
    value,
    resultdatedatetime,
    deleteddatetime
from {{ source('athenahealth_metadata', 'p4presultdata') }}
