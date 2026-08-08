{% macro normalize_risk_tier(expr) %}
CASE
  WHEN {{ expr }} IS NULL OR trim(cast({{ expr }} AS string)) = '' THEN NULL
  WHEN lower(trim(cast({{ expr }} AS string))) IN ('tier 1', 'tier1', '1', 'low risk', 'low') THEN 'Low Risk'
  WHEN lower(trim(cast({{ expr }} AS string))) IN ('tier 2', 'tier2', '2', 'rising risk', 'rising') THEN 'Rising Risk'
  WHEN lower(trim(cast({{ expr }} AS string))) IN ('tier 3', 'tier3', '3', 'high risk', 'high') THEN 'High Risk'
  WHEN lower(trim(cast({{ expr }} AS string))) IN ('tier 4', 'tier4', '4', 'highly complex', 'complex') THEN 'Highly Complex'
  ELSE trim(cast({{ expr }} AS string))
END
{% endmacro %}
