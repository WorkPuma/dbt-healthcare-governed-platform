{#
    Healthcare Constants Macros

    Centralized definitions for appointment types, statuses, and other
    business logic that should be consistent across all models.

    Usage:
        {{ awv_appointment_types() }}
        {{ completed_appointment_statuses() }}
        {{ medicare_product_types() }}
        {{ is_awv_appointment('apt.Type__c') }}
        {{ is_completed_appointment('apt.Status__c') }}
        {{ current_measurement_year() }}
#}

{# ==========================================================================
   AWV (Annual Wellness Visit) Appointment Types
   Used to identify AWV visits across Salesforce appointment records
   ========================================================================== #}

{% macro awv_appointment_types() %}
    ('Annual Wellness Visit', 'Telehealth AWV', 'Any 60 (AWV,PreOp,TOC)', 'Telehlth Any 60 (AWV, TOC)')
{% endmacro %}

{% macro is_awv_appointment(column) %}
    {{ column }} in {{ awv_appointment_types() }}
{% endmacro %}


{# ==========================================================================
   Completed Appointment Statuses — Salesforce
   Standard definition for "completed" appointments in Salesforce
   ========================================================================== #}

{% macro completed_appointment_statuses() %}
    ('charged entered', 'Checked Out', 'Checked In')
{% endmacro %}

{% macro is_completed_appointment(column) %}
    {{ column }} in {{ completed_appointment_statuses() }}
{% endmacro %}


{# ==========================================================================
   Athena Appointment Status Definitions

   Athena lifecycle: o (Open Slot) → f (Filled) → 2 (Checked In) →
                     3 (Checked Out) → 4 (Charge Entered) / x (Cancelled)

   "Completed" = patient has been seen. Once checked in (status 2), the visit
   is considered completed for scheduling, bonus, and operational purposes.
   Staff may be delayed in moving to Checked Out (3) or Charge Entered (4).

   IMPORTANT: Use these macros for ALL Athena appointment status checks.
   Do NOT hardcode status strings in models.
   ========================================================================== #}

{% macro athena_completed_statuses() %}
    ('2 - Checked In', '3 - Checked Out', '4 - Charge Entered')
{% endmacro %}

{% macro is_athena_completed(column) %}
    {{ column }} in {{ athena_completed_statuses() }}
{% endmacro %}

{% macro is_athena_completed_like(column) %}
    ({{ column }} LIKE '2 -%' OR {{ column }} LIKE '3 -%' OR {{ column }} LIKE '4 -%')
{% endmacro %}

{% macro is_athena_scheduled(column) %}
    {{ column }} LIKE 'f%'
{% endmacro %}

{% macro is_athena_cancelled(column) %}
    {{ column }} LIKE 'x%'
{% endmacro %}

{% macro is_athena_open_slot(column) %}
    {{ column }} LIKE 'o%'
{% endmacro %}


{# ==========================================================================
   Athena Department Exclusions

   Departments excluded from ALL core clinical / panel / revenue counts:
     -  1: Main Office — administrative dept, not patient care
           (added 2026-06-09; impact-checked: 0 patients change Active status,
           78 dept-1-only patients shift Inactive → Excluded)
     - 10: Vaccine Clinic — vaccination-only encounters, excluded from panel
     - 11: MIDI department — surfaced ONLY by vw_midi_appointments

   Use is_core_department() everywhere a model needs the canonical clinical
   appointment universe. Do NOT hardcode `DEPARTMENTID != 11` in new models.
   The MIDI-specific view (vw_midi_appointments.sql) intentionally inverts
   this and filters DEPARTMENTID = 11 directly.
   ========================================================================== #}

{% macro excluded_departments() %}
    (1, 10, 11)
{% endmacro %}

{% macro is_core_department(column) %}
    {{ column }} not in {{ excluded_departments() }}
{% endmacro %}


{# ==========================================================================
   Scheduled Appointment Status
   Appointment is scheduled but not yet completed
   ========================================================================== #}

{% macro scheduled_appointment_status() %}
    'filled'
{% endmacro %}

{% macro is_scheduled_appointment(column) %}
    {{ column }} = {{ scheduled_appointment_status() }}
{% endmacro %}


{# ==========================================================================
   Cancelled Appointment Status
   ========================================================================== #}

{% macro cancelled_appointment_status() %}
    'Cancelled'
{% endmacro %}

{% macro is_cancelled_appointment(column) %}
    {{ column }} = {{ cancelled_appointment_status() }}
{% endmacro %}


{# ==========================================================================
   Medicare Product Types
   Used to filter AWV-eligible Medicare patients
   ========================================================================== #}

{% macro medicare_product_types() %}
    ('Medicare PPO', 'Medicare HMO', 'Medicare Private FFS', 'Medicare B-Traditional')
{% endmacro %}

{% macro is_medicare_patient(column) %}
    {# DEPRECATED: All models now use patients.canonical_primary_is_medicare instead.
       This macro checks raw Salesforce PRIMARY_PRODUCT_TYPE__C which may be stale.
       Use: JOIN {{ ref('patients') }} and filter on canonical_primary_is_medicare = true #}
    {{ column }} in {{ medicare_product_types() }}
{% endmacro %}


{# ==========================================================================
   Measurement Year Functions
   Dynamic year calculations for rolling metrics
   ========================================================================== #}

{% macro current_measurement_year() %}
    year(current_date())
{% endmacro %}

{% macro is_current_year(date_column) %}
    year({{ date_column }}) = {{ current_measurement_year() }}
{% endmacro %}

{% macro is_year(date_column, year_offset=0) %}
    year({{ date_column }}) = {{ current_measurement_year() }} + {{ year_offset }}
{% endmacro %}


{# ==========================================================================
   TCM (Transitional Care Management) Constants
   ========================================================================== #}

{% macro tcm_appointment_types() %}
    ('TCM', 'Transitional Care Management', 'Any 60 (AWV,PreOp,TOC)', 'Telehlth Any 60 (AWV, TOC)')
{% endmacro %}


{# ==========================================================================
   Provider Activity (MDM-canonical)

   A provider is ACTIVE until their termination date (TriNet HRIS via MDM
   Provider) has passed. Toggling a provider off in Athena is NOT a proxy
   for anything and must not be used as an activity gate. Likewise, do NOT
   use `assigned_clinic != 'Inactive'` as an activity filter — that value
   is a clinic-assignment artifact (no future/recent appointment data),
   not an employment status.

   Use against mdm.reference_data.provider / stg_mdm__provider / providers,
   all of which carry the TriNet-sourced termination_date.
   ========================================================================== #}

{% macro is_provider_active(alias) %}
    ({{ alias }}.termination_date is null or {{ alias }}.termination_date >= current_date())
{% endmacro %}


{# ==========================================================================
   Patient Status Constants

   IMPORTANT: For patient status, always prefer joining int_patient_status_computed
   and using computed_status instead of raw Athena/Salesforce status codes.
   The computed status enforces:
     - Completed visit within 18 months = Active
     - No completed visit in 18 months = Inactive
     - Deceased/Inactive from Athena always honored
     - Appointments without completed visit = Prospect

   The raw status macros below are retained for models that operate directly on
   Athena patient records (before the computed status join is available).
   New models should use int_patient_status_computed.computed_status.
   ========================================================================== #}

{% macro active_patient_status() %}
    'a'
{% endmacro %}

{% macro inactive_patient_status() %}
    'i'
{% endmacro %}

{% macro prospect_patient_status() %}
    'p'
{% endmacro %}

{% macro is_active_patient(column) %}
    {# WARNING: This checks raw Athena/SF status code only. It does NOT apply
       the canonical 18-month inactivity rule or completed visit requirement.
       For accurate active patient filtering, join int_patient_status_computed
       and filter on computed_status = 'Active' instead. #}
    {{ column }} = {{ active_patient_status() }}
{% endmacro %}

{% macro computed_patient_status_values() %}
    {# Canonical computed_status values from int_patient_status_computed.
       Updated May 4 2026: added 'Re-Engaging' (rebooked after 18-month lapse)
       and 'New Lead' (registered ≤90d, no booking yet) and 'Excluded' (ghost
       / cold-lead bucket — exists since the revenue-eligibility refactor). #}
    ('Active', 'Inactive', 'Prospect', 'Deleted', 'Excluded', 'Re-Engaging', 'New Lead')
{% endmacro %}

{% macro is_active_patient_computed(column) %}
    {# Use this macro when filtering on int_patient_status_computed.computed_status
       or patients.patient_status (which inherits from computed_status).
       This is the CANONICAL definition of Active Patient.

       NOTE: 'Active' is strict — completed visit within 548 days. It does NOT
       include 'Re-Engaging' (rebooked but not yet visited) or 'New Lead'
       (registered, no booking yet). For broader "engaged with the practice"
       semantics, use is_engaged_patient_computed() below. #}
    {{ column }} = 'Active'
{% endmacro %}

{% macro is_engaged_patient_computed(column) %}
    {# Broader engagement filter: anyone the practice should treat as a live
       patient — Active, Re-Engaging (rebooked after lapse), Prospect (future
       visit booked, no completed yet), or New Lead (recently registered).
       Excludes Inactive, Deleted, and Excluded (ghost / cold-lead). #}
    {{ column }} in ('Active', 'Re-Engaging', 'Prospect', 'New Lead')
{% endmacro %}


{# ==========================================================================
   Payor TINs (compliance-critical attribution boundaries)

   The PAYOR_B H2001 risk contract roster (raw_uhc_members) lists members attributed
   to BOTH Healthcare Org NPIs and VendorBlue NPIs under the same contract.
   Per Healthcare policy, VendorBlue-attributed members are NOT Healthcare's patients:
   they must never enter EMPI / RAF / patient-level facts. They ARE surfaced in
   the medical-spend P&L as a separate 'VendorBlue' book (int_spend__vendorblue_book)
   so finance can see the full-contract economics, but they stay out of identity.

   These are the single source of truth for that boundary — used by
   int_payor__uhc_id_crosswalk (exclusion) and int_spend__vendorblue_book
   (inclusion). Do NOT hardcode these TINs in new models.
   ========================================================================== #}

{% macro herself_health_tin() %}
    '883504663'
{% endmacro %}

{% macro vendorblue_tin() %}
    '204841281'
{% endmacro %}
