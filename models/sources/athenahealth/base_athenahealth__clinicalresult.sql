{{
    config(
        tags=['athenahealth', 'clinicalresult', 'base']
    )
}}

/*
    Base passthrough for the raw athenahealth.athenaone.CLINICALRESULT Delta
    table.

    This is the ONLY model that reads the raw CLINICALRESULT source. Pure
    1:1 passthrough -- no filter, no rename -- shared by BOTH the quality
    funnel (stg_athena__clinicalresult, which drops deleteddatetime is not
    null itself) and provider_bonus (stg_bonus__quality_measures, inline
    reader).

    Per DEV-4296 shared-staging decision (PR #346 review, Data Engineer): one
    shared source read, consumer-specific filters stay downstream. See
    REDACTED_PATH
*/

select
    clinicalresultid,
    documentid,
    observationdatetime,
    resultsreporteddatetime,
    createddatetime,
    clinicalordertypeid,
    deleteddatetime
from {{ source('athenahealth_metadata', 'clinicalresult') }}
