{{
    config(
        materialized='table',
        liquid_clustered_by=['patient_id'],
        tags=['mdm', 'patient', 'status']
    )
}}

/*
  int_patient_status_computed — Computed Patient Status with Audit Dates

  DEV-4546: materialized as a liquid-clustered table (was a view). This is a
  hot-path spine read by patient_census, tier features, attribution, and many
  marts/tests. As a view it was recomputed on every read; persisting it once per
  build cuts that repeated computation. Liquid clustering on patient_id
  optimizes the downstream joins.

  Resolves conflict areas between Athena and Salesforce program rules:
    1. Active vs. Prospect: Active requires at least 1 completed visit
    2. 18-Month Inactivity: No completed visit in 548 days = Inactive
    3. Deceased: Patients with DECEASEDDATE set in Athena → Inactive
    4. Deleted: Athena status 'd' = chart removed/merged, NOT deceased

  NOTE: Athena PATIENTSTATUS 'd' means the chart was deleted or merged — it does
  NOT mean deceased. Actual death is tracked via the DECEASEDDATE field on the
  Athena patient record. Deceased patients typically have status 'i' in Athena.

  CANONICAL ACTIVE_DATE (2026-05-28, align with first completed visit):

  `active_date` is the date the patient completed their first visit.
  If they have not completed any visit, this is NULL.
  Sourced from the minimum completed appointment date.

  PRIORITY ORDER (10 priorities, last updated 2026-05-10 to add canonical
                  inactive_date formula from patient-funnel-progression canvas):
    1. Deceased (DECEASEDDATE set) → Inactive
    2. Athena 'd' → Deleted (chart removed)
    3. Has completed visit BUT last_completed > 548 days AND has future
       scheduled → Re-Engaging
    4. No completed visit ever AND has a future scheduled appointment → Prospect
    5. No completed visit ever AND registered ≤ 90 days ago → New Lead
    6. No completed visit ever AND no future scheduled appointment → Excluded
    7. 18-Month Inactivity Rule (last_completed > 548 days) → Inactive
    8. Athena 'i' → Inactive (voluntary, recent visit — audit date is real)
    9. Has completed visit ≤ 548 days → Active
   10. Fallback to Athena 'a' → Active (defensive; should not fire post-rule 6)

  CANONICAL INACTIVE DATE (dbtf v3 — 2026-06-05, "first transition" fix):

  The `inactive_date` column represents the actual date a patient transitioned
  to Inactive status, backdated to the earliest concrete evidence of
  disengagement. It is computed with a single unified formula for every
  non-deceased Inactive patient (covering BOTH the 18-Month Cliff path and the
  Athena Manual path):

    Deceased  → athena_deceased_date

    Otherwise → GREATEST(
                  last_completed_visit + 1 day,            -- floor
                  LEAST(
                    first_service_recovery_case_date,       -- (not yet wired)
                    last_substantive_outbound_call_date,    -- (not yet wired)
                    first_inactive_audit_after_lcv,         -- earliest manual
                                                            --   'i' ON/AFTER LCV
                    last_completed_visit + 548 days         -- 18-month cliff
                  )
                )

  The 18-month cliff participates in the LEAST as a CEILING, so:
    * Early manual flag (on/after LCV, before the cliff) → keeps its own date.
      [BUG FIX: previously these were re-dated forward to the cliff because the
       status branch order evaluated the > 548-day cliff before athena 'i'.]
    * Manual flag landing AFTER the cliff (late bookkeeping) → cliff wins.
    * No manual flag at all (silent attrition) → cliff.

  WHY "first_inactive_audit_after_lcv" (not the raw MIN over all 'i' audits):
  a manual 'i' from BEFORE the patient's most recent completed visit is stale
  (they came back and were seen), so it must not pull the date backward. We take
  the earliest 'i' audit on/after the last completed visit only.

  Because the cliff is always a real value inside the LEAST, the 9999-12-31
  sentinel used to coalesce the not-yet-wired sources can never leak into the
  result.

  Wiped to NULL if computed_status != 'Inactive'.

  Always floored at last_completed_visit + 1 day to enforce logical consistency.
  Salesforce "last touched" / "last modified" timestamps are NOT used because
  they conflate routine syncs with real decisions.

  NOTE: This changes the DATE only — every patient here stays classified as
  Inactive, so Inactive totals are unchanged; only the month a patient lands in
  moves (early-manual patients shift from the cliff month back to their true
  late-2024 inactivation dates).

  Sources for the inactive_date formula:
    - athena_deceased_date — athenahealth.athenaone.patient.DECEASEDDATE
    - last_completed_visit — MAX completed appointment date from athenaone.appointment
    - first_athena_inactive_audit_date — MIN EVENTDATETIME from patientaudit STATUS → 'i'
    - first_service_recovery_case_date — Athena Patient Cases module (TODO: source not wired,
      currently NULL — formula degrades to MIN over remaining sources)
    - last_substantive_outbound_call_date — NICE call center >30s outbound calls (TODO: source
      not wired, currently NULL — formula degrades to MIN over remaining sources)

  See: docs/dbtf-v2-migration.md (conflict register C4 + H6) and
       patient-funnel-progression canvas in Cursor canvases for full derivation.

  Department exclusions: All appointment scans use is_core_department()
  which excludes DEPARTMENTID IN (10, 11). Department 11 is MIDI (surfaced
  only via vw_midi_appointments). Department 10 is non-clinical / legacy.

  Sources:
    - stg_mdm__patient: current Athena status, demographics
    - athenahealth.athenaone.patient: DECEASEDDATE for true deceased detection
    - athenahealth.athenaone.appointment: completed visits and appointment history
    - athenahealth.athenaone.patientaudit: status change audit trail

  Grain: One row per patient_id

  See: https://HealthcareOrg.atlassian.net/wiki/spaces/dev/pages/630063164
*/

with mdm_patient as (

    select
        patient_id,
        patient_status as athena_status
    from {{ ref('stg_mdm__patient') }}

),

-- Registration date drives the New Lead vs Excluded split for patients who
-- have never completed a visit. Sourced directly from Athena (REGISTRATIONDATE)
-- because stg_mdm__patient does not currently expose it.
patient_registration as (

    select
        cast(PATIENTID as bigint) as patient_id,
        REGISTRATIONDATE          as registration_date
    from {{ source('athenahealth', 'patient') }}

),

-- Single-pass appointment aggregation: visit counts + last completed date
patient_appointments as (

    select
        cast(a.PATIENTID as bigint) as patient_id,
        count(
            case when {{ is_athena_completed('a.APPOINTMENTSTATUS') }} then 1 end
        ) as completed_visit_count,
        count(
            case when a.APPOINTMENTSTATUS != 'o - Open Slot' then 1 end
        ) as any_appointment_count,
        max(
            case when {{ is_athena_completed('a.APPOINTMENTSTATUS') }}
                 then a.APPOINTMENTDATE end
        ) as last_completed_appointment,
        min(
            case when {{ is_athena_completed('a.APPOINTMENTSTATUS') }}
                 then a.APPOINTMENTDATE end
        ) as first_completed_appointment
    from {{ source('athenahealth', 'appointment') }} a
    where {{ is_core_department('a.DEPARTMENTID') }}
      -- Cheap pre-filter: keep only rows that contribute to either count or MAX
      and a.APPOINTMENTSTATUS != 'o - Open Slot'
    group by 1

),

-- Future scheduled appointments — drives the Prospect bucket for patients
-- with no completed visit yet but a real upcoming visit on the books.
patient_future_scheduled as (

    select
        cast(a.PATIENTID as bigint) as patient_id,
        count(*) as future_scheduled_count,
        min(a.APPOINTMENTDATE) as next_scheduled_appointment
    from {{ source('athenahealth', 'appointment') }} a
    where {{ is_core_department('a.DEPARTMENTID') }}
      and {{ is_athena_scheduled('a.APPOINTMENTSTATUS') }}
      and a.APPOINTMENTDATE >= current_date()
      and a.APPOINTMENTCANCELLEDDATETIME is null
    group by 1

),

-- Single-pass patientaudit aggregation pivoted by NEWVALUE
-- Adds first_athena_inactive_audit_date (MIN) for the canonical
-- inactive_date formula's "first evidence of disengagement" rule.
--
-- NOTE: athena_active_audit_date is the legacy audit-derived active date
-- (MAX of NEWVALUE='a' EVENTDATETIME). It is retained for debugging and
-- backward-compat lookups. The canonical public-facing `active_date` is the
-- date the patient completed their FIRST visit (first_completed_appointment;
-- see the final select). Salesforce First_Scheduled_Date__pc is retained only
-- as the diagnostic sf_first_scheduled_at column, not as the active_date anchor.
patient_audit_dates as (

    select
        cast(SOURCEID as bigint) as patient_id,
        max(case when NEWVALUE = 'a' then EVENTDATETIME end) as athena_active_audit_date,
        max(case when NEWVALUE = 'i' then EVENTDATETIME end) as athena_inactive_date,
        min(case when NEWVALUE = 'i' then EVENTDATETIME end) as first_athena_inactive_audit_date,
        max(case when NEWVALUE = 'p' then EVENTDATETIME end) as prospect_date,
        max(case when NEWVALUE = 'd' then EVENTDATETIME end) as deleted_date
    from {{ source('athenahealth', 'patientaudit') }}
    where FIELDNAME = 'STATUS'
      and NEWVALUE in ('a', 'i', 'p', 'd')
    group by 1

),

-- Earliest manual Athena 'i' audit that occurred ON OR AFTER the patient's last
-- completed visit. This is the "real early inactivation date" the unified
-- inactive_date formula uses as its first evidence of disengagement.
--
-- Constraining to EVENTDATETIME >= last_completed_appointment is deliberate:
-- a manual 'i' from BEFORE the most recent completed visit is stale (the patient
-- returned and was seen), and must not pull the inactivation date backward.
-- This is why we cannot reuse first_athena_inactive_audit_date (the raw MIN over
-- ALL 'i' audits) — that MIN could be an obsolete pre-visit flag.
inactive_audit_after_lcv as (

    select
        cast(aud.SOURCEID as bigint) as patient_id,
        min(aud.EVENTDATETIME)       as first_inactive_audit_after_lcv
    from {{ source('athenahealth', 'patientaudit') }} aud
    inner join patient_appointments pa
        on cast(aud.SOURCEID as bigint) = pa.patient_id
    where aud.FIELDNAME = 'STATUS'
      and aud.NEWVALUE = 'i'
      and pa.last_completed_appointment is not null
      and aud.EVENTDATETIME >= pa.last_completed_appointment
    group by 1

),

-- Diagnostic only: Salesforce First_Scheduled_Date__pc, the first appointment
-- created in SF with status Scheduled/Confirmed (set one-time, monotonic).
-- Exposed as sf_first_scheduled_at for reconciliation. NOTE: this is NOT the
-- canonical active_date — active_date is first_completed_appointment (the date
-- the first visit was COMPLETED, not merely scheduled).
sf_first_scheduled as (

    select
        cast(patient_id as bigint) as patient_id,
        cast(first_scheduled_date as timestamp) as first_scheduled_at
    from {{ ref('stg_salesforce__account') }}
    where patient_id is not null
      and first_scheduled_date is not null

),

athena_deceased as (

    select
        cast(PATIENTID as bigint) as patient_id,
        DECEASEDDATE as athena_deceased_date
    from {{ source('athenahealth', 'patient') }}
    where DECEASEDDATE is not null

),

-- Service-recovery / mark-inactive cases (Athena Patient Cases module)
-- TODO: wire to athenahealth.athenaone.patientcase (or equivalent) when source
-- is available. For now, returns NULL for every patient so the inactive_date
-- formula's MIN() degrades to the remaining wired sources.
service_recovery_cases as (

    select
        cast(NULL as bigint) as patient_id,
        cast(NULL as timestamp) as first_service_recovery_case_date
    where 1 = 0

),

-- Last substantive outbound call (NICE call center, duration > 30 seconds)
-- TODO: wire to NICE Enlighten / call center source when integration is live.
-- For now, returns NULL so the formula degrades.
outbound_calls_substantive as (

    select
        cast(NULL as bigint) as patient_id,
        cast(NULL as timestamp) as last_substantive_outbound_call_date
    where 1 = 0

),

combined as (

    select
        p.patient_id,
        p.athena_status,

        coalesce(pa.completed_visit_count, 0) as completed_visit_count,
        coalesce(pa.any_appointment_count, 0) as any_appointment_count,
        pa.last_completed_appointment,

        coalesce(pa.completed_visit_count, 0) > 0 as has_completed_visit,
        coalesce(pa.any_appointment_count, 0) > 0 as has_any_appointment,

        coalesce(pfs.future_scheduled_count, 0) > 0 as has_future_scheduled,
        pfs.next_scheduled_appointment,
        pa.first_completed_appointment,

        case
            when pa.last_completed_appointment is not null
            then datediff(current_date(), pa.last_completed_appointment)
        end as days_since_last_completed,

        -- Canonical active_date: the date the first visit was completed (non-null if has_completed_visit).
        cast(pa.first_completed_appointment as timestamp) as active_date,
        sfs.first_scheduled_at                 as sf_first_scheduled_at,
        pad.athena_active_audit_date           as athena_active_audit_date,
        pad.athena_inactive_date,
        pad.first_athena_inactive_audit_date,
        iaa.first_inactive_audit_after_lcv,
        pad.prospect_date,
        pad.deleted_date,
        adec.athena_deceased_date,

        src.first_service_recovery_case_date,
        oc.last_substantive_outbound_call_date,

        preg.registration_date,
        case
            when preg.registration_date is not null
            then datediff(current_date(), preg.registration_date)
        end as days_since_registration

    from mdm_patient p
    left join patient_appointments pa            on p.patient_id = pa.patient_id
    left join patient_future_scheduled pfs       on p.patient_id = pfs.patient_id
    left join patient_audit_dates pad            on p.patient_id = pad.patient_id
    left join inactive_audit_after_lcv iaa       on p.patient_id = iaa.patient_id
    left join sf_first_scheduled sfs             on p.patient_id = sfs.patient_id
    left join athena_deceased adec               on p.patient_id = adec.patient_id
    left join patient_registration preg          on p.patient_id = preg.patient_id
    left join service_recovery_cases src         on p.patient_id = src.patient_id
    left join outbound_calls_substantive oc      on p.patient_id = oc.patient_id

),

with_computed_status as (

    select
        *,

        -- See header comment for full priority order (10 priorities)
        case
            when athena_deceased_date is not null then 'Inactive'
            when athena_status = 'd' then 'Deleted'
            when has_completed_visit
                 and days_since_last_completed > 548
                 and has_future_scheduled then 'Re-Engaging'
            when not has_completed_visit and has_future_scheduled then 'Prospect'
            when not has_completed_visit
                 and days_since_registration is not null
                 and days_since_registration <= 90 then 'New Lead'
            when not has_completed_visit then 'Excluded'
            when days_since_last_completed > 548 then 'Inactive'
            when athena_status = 'i' then 'Inactive'
            when days_since_last_completed <= 548 then 'Active'
            else case athena_status
                when 'a' then 'Active'
                when 'p' then 'Prospect'
            end
        end as computed_status,

        case
            when athena_deceased_date is not null then 'Deceased (Athena Deceased Date)'
            when athena_status = 'd' then 'Athena Deleted (Chart Removed)'
            when has_completed_visit
                 and days_since_last_completed > 548
                 and has_future_scheduled
                then 'Re-Engaging - Rebooked After 18-Month Lapse'
            when not has_completed_visit and has_future_scheduled
                then 'Prospect - Future Scheduled, No Completed Visit Yet'
            when not has_completed_visit
                 and days_since_registration is not null
                 and days_since_registration <= 90
                then 'New Lead - Registered Within 90 Days, No Booking Yet'
            when not has_completed_visit and has_any_appointment
                then 'Excluded - Past Appointments Only, No Future Scheduled'
            when not has_completed_visit
                then 'Excluded - No Completed Visit Ever'
            when days_since_last_completed > 548
                then '18-Month Inactivity Rule'
            when athena_status = 'i' then 'Athena Manual Inactive'
            when days_since_last_completed <= 548
                then 'Completed Visit Within 18 Months'
            else 'Athena Fallback'
        end as status_reason,

        -- Helper: 18-month cliff date (LCV + 548 days). Used by both the
        -- 18-Month Inactivity Rule branch and as the snap-to ceiling for the
        -- Athena Manual branch when audit dates are stale.
        case
            when has_completed_visit
            then date_add(last_completed_appointment, 548)
        end as computed_inactive_date,

        -- Floor: LCV + 1 day. Inactive date can never precede the day after
        -- the last completed visit (logical consistency).
        case
            when has_completed_visit
            then date_add(last_completed_appointment, 1)
        end as inactive_floor_date

    from combined

),

with_inactive_date as (

    select
        *,

        -- Canonical inactive_date formula (see header comment).
        -- Wiped to NULL when the patient is not in Inactive status.
        case
            -- Deceased branch: actual death date always wins.
            when athena_deceased_date is not null
                then athena_deceased_date

            -- Unified "first transition" formula for every other Inactive
            -- patient (covers BOTH the 18-Month Cliff and Athena Manual paths):
            --
            --   inactive_date = GREATEST(
            --       LCV + 1 day,                          -- floor
            --       LEAST(first evidence of disengagement,
            --             LCV + 548 days)                 -- 18-month cliff
            --   )
            --
            -- The cliff (computed_inactive_date) participates in the LEAST as a
            -- ceiling, so an early manual flag keeps its own date while a late
            -- (or absent) flag falls back to the cliff. Because the cliff is
            -- always a real value, the 9999-12-31 sentinel can never leak.
            when computed_status = 'Inactive'
                then greatest(
                    cast(inactive_floor_date as timestamp),
                    least(
                        coalesce(first_service_recovery_case_date,   cast('9999-12-31' as timestamp)),
                        coalesce(last_substantive_outbound_call_date, cast('9999-12-31' as timestamp)),
                        coalesce(first_inactive_audit_after_lcv,      cast('9999-12-31' as timestamp)),
                        least(
                            cast(computed_inactive_date as timestamp),
                            cast(current_date() as timestamp)
                        )
                    )
                )

            -- Wipe when not Inactive
            else null
        end as inactive_date

    from with_computed_status

)

select
    patient_id,
    athena_status,
    computed_status,
    status_reason,

    has_completed_visit,
    has_any_appointment,
    has_future_scheduled,
    completed_visit_count,
    any_appointment_count,
    last_completed_appointment,
    next_scheduled_appointment,
    days_since_last_completed,
    registration_date,
    days_since_registration,

    -- Public-facing audit dates
    active_date,                  -- canonical: first_completed_appointment (date of first completed visit)
    sf_first_scheduled_at,        -- raw SF First_Scheduled_Date__pc (diagnostic)
    athena_active_audit_date,     -- legacy audit-derived active date (diagnostic)
    inactive_date,                -- canonical (priority formula above)
    prospect_date,
    deleted_date,
    athena_deceased_date

from with_inactive_date
