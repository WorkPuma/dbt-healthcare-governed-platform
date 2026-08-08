{#
  normalize_icd(col)
  Returns a canonical ICD-10-CM code string suitable for joining across
  sources that disagree on case and dot-formatting (e.g. "e10" vs "E10" vs
  "E10.9" vs "E109"). Enforces the constitution rule that ALL ICD-10 joins
  and comparisons must be normalized on BOTH sides.

  Steps:
    1. cast to string (defensive — some sources carry non-string types)
    2. trim whitespace
    3. uppercase
    4. strip all '.' characters

  Example:
    'e10.9'  -> 'E109'
    'E10'    -> 'E10'
    'E109'   -> 'E109'
#}

{% macro normalize_icd(col) %}
upper(regexp_replace(trim(cast({{ col }} as string)), '\\.', ''))
{% endmacro %}
