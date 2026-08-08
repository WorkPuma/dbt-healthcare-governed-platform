{#
  raf_sweep_window — classify a risk-adjustment diagnosis into the CMS submission
  "sweep" (run) it first qualified for, based on its earliest ELIGIBLE submission
  date versus the CMS HPMS deadlines for its DOS year
  (ref_finraf__ra_submission_deadlines).

  Shared by int_raf__mao004_eligibility (diagnosis grain) and int_raf__scored_hccs
  (HCC grain rollup) so the bucket boundaries live in exactly one place.

  Returns one of: INITIAL / MIDYEAR / FINAL / POST_FINAL / N_A / UNKNOWN
    N_A     — diagnosis is not RA-eligible or has no eligible submission date
    UNKNOWN — DOS year has no row in the deadline seed

  Args are SQL expressions (column references) from the caller's scope:
    is_eligible          boolean — diagnosis is RA-eligible
    first_eligible_date  date    — MIN(submission_date) among eligible encounters
    initial_deadline / midyear_deadline / final_deadline  date — from the seed
    dos_year             int     — the deadline-seed key (null when unmatched)
#}
{% macro raf_sweep_window(is_eligible, first_eligible_date, initial_deadline, midyear_deadline, final_deadline, dos_year) %}
        case
            -- coalesce the eligibility flag: a NULL boolean must read as
            -- not-eligible (N_A), not fall through `NOT null` (which is null,
            -- not true) into a sweep bucket.
            when not coalesce({{ is_eligible }}, false)
                or {{ first_eligible_date }} is null            then 'N_A'
            when {{ dos_year }} is null                         then 'UNKNOWN'
            -- A matched DOS year with a missing deadline cannot be bucketed;
            -- treat as UNKNOWN rather than letting the null `<=` comparisons
            -- silently default the row to POST_FINAL.
            when {{ initial_deadline }} is null
                or {{ midyear_deadline }} is null
                or {{ final_deadline }} is null                 then 'UNKNOWN'
            when {{ first_eligible_date }} <= {{ initial_deadline }} then 'INITIAL'
            when {{ first_eligible_date }} <= {{ midyear_deadline }} then 'MIDYEAR'
            when {{ first_eligible_date }} <= {{ final_deadline }}   then 'FINAL'
            else 'POST_FINAL'
        end
{% endmacro %}
