{#
  MDM Compliance Helper Macros
  ============================
  
  DETECTION: MDM compliance is enforced via Python script
  Run: `python scripts/check_mdm_compliance.py`
  
  This validates that models referencing AthenaHealth source tables 
  also include the required MDM source in their dependencies.
  
  DATABRICKS UNITY CATALOG STRUCTURE:
  ===================================
  AthenaHealth Data (use athenahealth.athenaone.*):
    - athenahealth.athenaone.appointment
    - athenahealth.athenaone.appointmenttype
    - athenahealth.athenaone.provider
    - athenahealth.athenaone.department
    - athenahealth.athenaone.patient
    - athenahealth.athenaone.patientinsurance
    - athenahealth.athenaone.insurancepackage
  
  MDM Reference Data (mdm.reference_data.*):
    - mdm.reference_data.appointment_type  -> patient_visit = true AND review_status = 'Reviewed'
    - mdm.reference_data.provider          -> non_provider <> true (actual providers only)
    - mdm.reference_data.location          -> Patient_Department = true (patient-facing)
    - mdm.reference_data.patient           -> deleted_yn = 'N' AND test_patient_yn = 'N'
    - mdm.reference_data.insurance         -> (no filters - just require join)
  
  EXEMPTIONS (add to model's schema.yml config):
    meta:
      mdm_exempt: true
      mdm_exempt_reason: "Reason for exemption"
      mdm_exempt_approved_by: "REDACTED_EMAIL"
      mdm_exempt_date: "2025-01-15"
  
  Or exempt specific rules:
    meta:
      mdm_exempt_appointment: true
      mdm_exempt_provider: true
      mdm_exempt_department: true
      mdm_exempt_patient: true
      mdm_exempt_insurance: true
#}

{# 
  Dictionary of source tables and their required MDM joins
  Format: source_table -> (mdm_table, join_column, required_filters)
#}
{% macro get_mdm_compliance_rules() %}
  {% set rules = {
    'athenahealth.athenaone.appointment': {
      'mdm_table': 'mdm.appointment_type',
      'join_column': 'appointment_type_id',
      'required_filters': ['patient_visit = true', "review_status = 'reviewed'"],
      'test_name': 'mdm_appointment_type_joined'
    },
    'athenahealth.athenaone.appointmenttype': {
      'mdm_table': 'mdm.appointment_type',
      'join_column': 'appointment_type_id', 
      'required_filters': ['patient_visit = true', "review_status = 'reviewed'"],
      'test_name': 'mdm_appointment_type_joined'
    },
    'athenahealth.athenaone.provider': {
      'mdm_table': 'mdm.provider',
      'join_column': 'provider_id',
      'required_filters': ['non_provider <> true'],
      'test_name': 'mdm_provider_joined'
    },
    'athenahealth.athenaone.department': {
      'mdm_table': 'mdm.department',
      'join_column': 'department_id',
      'required_filters': ['Patient_Department = true'],
      'test_name': 'mdm_location_joined'
    },
    'athenahealth.athenaone.patient': {
      'mdm_table': 'mdm.patient',
      'join_column': 'patient_id',
      'required_filters': ["deleted_yn = 'N'", "test_patient_yn = 'N'"],
      'test_name': 'mdm_patient_joined'
    },
    'athenahealth.athenaone.insurancepackage': {
      'mdm_table': 'mdm.insurance_package',
      'join_column': 'insurance_package_id',
      'required_filters': [],
      'test_name': 'mdm_insurance_joined'
    },
    'snowflake_databricks.dm_appointments_scheduling_consolidated': {
      'mdm_table': 'mdm.appointment_type',
      'join_column': 'appointment_type_id',
      'required_filters': ['patient_visit = true', "review_status = 'reviewed'"],
      'test_name': 'mdm_appointment_type_joined'
    }
  } %}
  {{ return(rules) }}
{% endmacro %}


{#
  Macro to get MDM table for a given source
  Usage: {{ get_mdm_table_for_source('athenahealth.athenaone.provider') }}
#}
{% macro get_mdm_table_for_source(source_identifier) %}
  {% set rules = get_mdm_compliance_rules() %}
  {% if source_identifier in rules %}
    {{ return(rules[source_identifier]['mdm_table']) }}
  {% else %}
    {{ return(none) }}
  {% endif %}
{% endmacro %}


{#
  Macro to validate a model's MDM compliance at compile time
  This runs during dbt compile/run and logs warnings
  
  Usage in model:
    {{ validate_mdm_compliance(this) }}
#}
{% macro validate_mdm_compliance(model_node) %}
  {# This is informational - actual validation happens in tests #}
  {% if execute %}
    {% set model_meta = model_node.config.get('meta', {}) %}
    {% if model_meta.get('mdm_exempt', false) %}
      {{ log("MDM EXEMPT: " ~ model_node.name ~ " - Reason: " ~ model_meta.get('mdm_exempt_reason', 'No reason provided'), info=true) }}
    {% endif %}
  {% endif %}
{% endmacro %}


{#
  Helper macro to check if model is MDM exempt
#}
{% macro is_mdm_exempt(model_name) %}
  {% set model_node = graph.nodes.get('model.' ~ project_name ~ '.' ~ model_name, none) %}
  {% if model_node %}
    {% set meta = model_node.config.get('meta', {}) %}
    {{ return(meta.get('mdm_exempt', false)) }}
  {% endif %}
  {{ return(false) }}
{% endmacro %}


{#
  Macro to generate MDM join SQL snippet
  Usage: {{ mdm_join('appointment_type', 'appt.APPOINTMENT_TYPE_ID') }}
#}
{% macro mdm_join(mdm_table_name, source_column, alias='mdm') %}
INNER JOIN {{ source('mdm', mdm_table_name) }} AS {{ alias }}
    ON {{ source_column }} = {{ alias }}.{{ mdm_table_name }}_id
{% endmacro %}


{#
  Macro to generate standard MDM filters
  Usage: {{ mdm_standard_filters('mdm', 'appointment_type') }}
#}
{% macro mdm_standard_filters(alias, mdm_type) %}
  {% if mdm_type == 'appointment_type' %}
    AND {{ alias }}.patient_visit = true
    AND {{ alias }}.review_status = 'reviewed'
  {% elif mdm_type == 'provider' %}
    AND ({{ alias }}.non_provider <> true OR {{ alias }}.non_provider IS NULL)
  {% elif mdm_type == 'patient' %}
    AND {{ alias }}.deleted_yn = 'N'
    AND {{ alias }}.test_patient_yn = 'N'
  {% elif mdm_type == 'department' or mdm_type == 'location' %}
    AND {{ alias }}.Patient_Department = true
  {% elif mdm_type == 'insurance_package' or mdm_type == 'insurance' %}
    {# No additional filters required for insurance - just join #}
  {% endif %}
{% endmacro %}
