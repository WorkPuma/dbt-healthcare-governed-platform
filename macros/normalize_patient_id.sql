{% macro normalize_patient_id(col) %}
{#-
  Canonical patient_id normalizer: strip a trailing .0 from float-typed ids
  (100002.0 -> "100002"), pass clean integer strings through, and REJECT (null)
  any non-integer value. Never rounds a malformed id to a different patient.
-#}
    case
        when {{ col }} is null then null
        when cast({{ col }} as string) rlike '^[0-9]+(\\.0+)?$'
            then regexp_replace(cast({{ col }} as string), '\\.0+$', '')
        else null
    end
{% endmacro %}
