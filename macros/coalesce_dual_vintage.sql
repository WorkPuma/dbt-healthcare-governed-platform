{# Dual-vintage column helpers for PAYOR_B revenue (pre/post UHC_REVENUE_COLUMN_MAP). #}

{% macro relation_colnames_lower(relation) %}
  {%- if execute -%}
    {%- set cols = adapter.get_columns_in_relation(relation) | map(attribute='name') | map('lower') | list -%}
  {%- else -%}
    {# Parse/docs-safe defaults: assume both vintages so compile never fails. #}
    {%- set cols = [
      'parta_pmt', 'tot_part_a_ma_amt',
      'partb_pmt', 'tot_part_b_ma_amt',
      'risk_adjuster_factor_b', 'risk_adj_fctr_b',
      'lti_flg', 'lti',
      'gross_revenue'
    ] -%}
  {%- endif -%}
  {{ return(cols) }}
{% endmacro %}

{% macro coalesce_dual_vintage_numeric(colnames, primary_col, legacy_col) -%}
  {%- set has_primary = primary_col in colnames -%}
  {%- set has_legacy = legacy_col in colnames -%}
  {%- if has_primary and has_legacy -%}
  coalesce(
      {{ clean_numeric_string(primary_col) }},
      {{ clean_numeric_string(legacy_col) }}
  )
  {%- elif has_primary -%}
  {{ clean_numeric_string(primary_col) }}
  {%- elif has_legacy -%}
  {{ clean_numeric_string(legacy_col) }}
  {%- else -%}
  cast(null as double)
  {%- endif -%}
{%- endmacro %}

{% macro coalesce_dual_vintage_double_cast(colnames, primary_col, legacy_col) -%}
  {%- set has_primary = primary_col in colnames -%}
  {%- set has_legacy = legacy_col in colnames -%}
  {%- if has_primary and has_legacy -%}
  coalesce(
      try_cast(nullif(trim(cast({{ primary_col }} as string)), '') as double),
      try_cast(nullif(trim(cast({{ legacy_col }} as string)), '') as double)
  )
  {%- elif has_primary -%}
  try_cast(nullif(trim(cast({{ primary_col }} as string)), '') as double)
  {%- elif has_legacy -%}
  try_cast(nullif(trim(cast({{ legacy_col }} as string)), '') as double)
  {%- else -%}
  cast(null as double)
  {%- endif -%}
{%- endmacro %}

{% macro coalesce_dual_vintage_flag(colnames, primary_col, legacy_col) -%}
  {%- set has_primary = primary_col in colnames -%}
  {%- set has_legacy = legacy_col in colnames -%}
  {%- if has_primary and has_legacy -%}
  upper(coalesce(nullif(trim({{ primary_col }}), ''), nullif(trim({{ legacy_col }}), '')))
  {%- elif has_primary -%}
  upper(nullif(trim({{ primary_col }}), ''))
  {%- elif has_legacy -%}
  upper(nullif(trim({{ legacy_col }}), ''))
  {%- else -%}
  cast(null as string)
  {%- endif -%}
{%- endmacro %}
