{% macro parse_claim_date(col) %}
{#-
  Parse a date stored as a raw string into a true DATE, tolerant of the
  formats PAYOR_A emits across release vintages:
    - "YYYY-MM-DD" / timestamp-prefixed strings (Excel rolling files)
    - "M/D/YYYY" / "MM/DD/YYYY"
    - "YYYY/MM/DD" / "YYYY/M/D" (annual Claims*.txt extracts)
    - "YYYYMMDD"
  Slash forms are normalized to dashes once, then parsed — avoids stacking
  separate try_to_timestamp calls per delimiter variant.
  Returns NULL when nothing parses, so a malformed value never silently
  becomes "today" or errors the build. Used to keep every claims date
  DATE-typed and timezone-stable end-to-end (V3 dev-guide hard
  requirement: date_column must be DATE).
-#}
{%- set raw -%}trim(cast({{ col }} as string)){%- endset -%}
{%- set slash_normalized -%}regexp_replace({{ raw }}, '/', '-'){%- endset -%}
coalesce(
    try_cast({{ col }} as date),
    try_cast(try_to_timestamp({{ slash_normalized }}, 'yyyy-M-d') as date),
    try_cast(try_to_timestamp({{ raw }}, 'M/d/yyyy') as date),
    try_cast(try_to_timestamp({{ raw }}, 'yyyyMMdd') as date),
    try_cast(try_to_timestamp({{ col }}) as date)
)
{% endmacro %}
