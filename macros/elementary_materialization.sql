-- Elementary Materialization Override
-- Required for dbt 1.8+ to allow Elementary to override default test materializations
-- https://docs.elementary-data.com/cloud/onboarding/quickstart-dbt-package

{% materialization test, default %}
{{ return(elementary.materialization_test_default()) }}
{% endmaterialization %}
