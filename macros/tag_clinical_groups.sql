{#
  tag_clinical_groups — derive ARRAY<STRING> of clinical-group tags for the ICD reference dim.

  Used by `dim_icd_categorization`. Each tag is a UNION of multiple sources so the rollup
  is robust:
    - AHRQ CCSR body system code (NEO, RSP, CIR, END, GEN, etc.)
    - HCC v28 hierarchy group top HCCs (e.g., 17 = Cancer Metastatic family)
    - ICD prefix patterns for codes that aren't in HCC/CCSR but are clinically relevant
      (e.g., I27.x cor pulmonale = pulmonary disease that lives under CCSR's Circulatory
      body system, so we manually pull it into PULMONARY_BROAD)

  Each tag is documented with WHY it's defined this way so future maintainers can audit.
  Five tags ship in v1; add more in v2 by extending the array_compact() literal.

  Args:
    body_sys      — ccsr_body_system_code (e.g., 'NEO', 'RSP', 'CIR', 'END')
    hcc_top_ids   — hcc_v28_group_top_hcc_ids (array of int — the rank-1 family heads)
    icd           — icd_10_cm (no-dot format, e.g., 'E1122')
#}
{% macro tag_clinical_groups(body_sys, hcc_top_ids, icd) %}
  array_compact(array(

    CASE
      WHEN {{ body_sys }} = 'RSP'
           OR ARRAYS_OVERLAP({{ hcc_top_ids }}, ARRAY(276))
           OR {{ icd }} LIKE 'I27%'
           OR {{ icd }} LIKE 'J%'
      THEN 'PULMONARY_BROAD'
    END,

    CASE
      WHEN {{ body_sys }} = 'CIR'
           OR ARRAYS_OVERLAP({{ hcc_top_ids }}, ARRAY(221, 211))
           OR ({{ icd }} LIKE 'I%' AND {{ icd }} NOT LIKE 'I27%')
      THEN 'CARDIOVASCULAR_BROAD'
    END,

    CASE
      WHEN {{ body_sys }} = 'NEO'
           OR ARRAYS_OVERLAP({{ hcc_top_ids }}, ARRAY(10, 11, 17))
           OR {{ icd }} LIKE 'C%'
           OR {{ icd }} RLIKE '^D[0-4]'
      THEN 'ONCOLOGY_BROAD'
    END,

    CASE
      WHEN ARRAYS_OVERLAP({{ hcc_top_ids }}, ARRAY(35))
           OR {{ icd }} LIKE 'E08%'
           OR {{ icd }} LIKE 'E09%'
           OR {{ icd }} LIKE 'E10%'
           OR {{ icd }} LIKE 'E11%'
           OR {{ icd }} LIKE 'E12%'
           OR {{ icd }} LIKE 'E13%'
      THEN 'DIABETES'
    END,

    CASE
      WHEN ARRAYS_OVERLAP({{ hcc_top_ids }}, ARRAY(326))
           OR {{ icd }} LIKE 'N18%'
           OR {{ icd }} LIKE 'N19%'
           OR {{ icd }} = 'Z992'
      THEN 'RENAL_CKD'
    END

  ))
{% endmacro %}
