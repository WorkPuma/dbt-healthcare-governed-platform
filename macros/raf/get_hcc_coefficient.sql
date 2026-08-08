{% macro get_hcc_coefficient(hcc_code_column, eligibility_segment_column) %}
/*
  Macro: get_hcc_coefficient

  Replaces: TWICE.DEV_STAGE.GET_HCC_COEFFICIENT Snowflake UDF

  Looks up the disease coefficient for a given HCC code and
  eligibility segment from CMS V28 seed data.

  FIX B20: Supports all 9 CMS eligibility segments, not just CNA.

  Usage:
    {{ get_hcc_coefficient('hcc_code', 'eligibility_segment') }}
*/
(
    select coalesce(c.coefficient_value, 0)
    from {{ ref('cms_hcc_v28__all_coefficients') }} c
    where c.coefficient_type = 'disease'
      and c.coefficient_key = concat({{ eligibility_segment_column }}, '_', {{ hcc_code_column }})
    limit 1
)
{% endmacro %}
