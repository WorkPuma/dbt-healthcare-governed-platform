{% macro calculate_demographic_risk(patient_dob_column, patient_sex_column, eligibility_segment_column) %}
/*
  Macro: calculate_demographic_risk

  Replaces: TWICE.DEV_STAGE.CALCULATE_DEMOGRAPHIC_RISK Snowflake UDF

  Calculates the CMS demographic risk factor based on age, sex, and
  eligibility segment using V28 coefficient seed data.

  FIX B19: Uses actual patient sex, NOT hardcoded 'F'.
  FIX B20: Supports all 9 CMS eligibility segments.

  Age bands (CMS V28):
    0_34, 35_44, 45_54, 55_59, 60_64, 65_69, 70_74, 75_79, 80_84, 85_89, 90_94, 95_GT

  Usage:
    {{ calculate_demographic_risk('date_of_birth', 'sex_code', 'eligibility_segment') }}
*/
(
    select coalesce(c.coefficient_value, 0)
    from {{ ref('cms_hcc_v28__all_coefficients') }} c
    where c.coefficient_type = 'demographic'
      and c.coefficient_key = concat(
          {{ eligibility_segment_column }},
          '_',
          {{ patient_sex_column }},
          case
              when floor(datediff(current_date(), {{ patient_dob_column }}) / 365.25) < 35 then '0_34'
              when floor(datediff(current_date(), {{ patient_dob_column }}) / 365.25) < 45 then '35_44'
              when floor(datediff(current_date(), {{ patient_dob_column }}) / 365.25) < 55 then '45_54'
              when floor(datediff(current_date(), {{ patient_dob_column }}) / 365.25) < 60 then '55_59'
              when floor(datediff(current_date(), {{ patient_dob_column }}) / 365.25) < 65 then '60_64'
              when floor(datediff(current_date(), {{ patient_dob_column }}) / 365.25) < 70 then '65_69'
              when floor(datediff(current_date(), {{ patient_dob_column }}) / 365.25) < 75 then '70_74'
              when floor(datediff(current_date(), {{ patient_dob_column }}) / 365.25) < 80 then '75_79'
              when floor(datediff(current_date(), {{ patient_dob_column }}) / 365.25) < 85 then '80_84'
              when floor(datediff(current_date(), {{ patient_dob_column }}) / 365.25) < 90 then '85_89'
              when floor(datediff(current_date(), {{ patient_dob_column }}) / 365.25) < 95 then '90_94'
              else '95_GT'
          end
      )
    limit 1
)
{% endmacro %}
