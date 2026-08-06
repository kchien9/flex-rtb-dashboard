-- SDR Funnel, by Segment -- feeds the small-multiples funnel section on the Activities tab.
-- Kevin: "i kinda want to do a segment waterfall view... meetings booked, meetings held,
-- calls/emails, inbound vs outbound... sourced opportunities (this is just pipeline created)."
--
-- SMALL MULTIPLES, NOT ONE FILTERED CHART -- brainstormed with Kevin first: a single chart
-- with a segment/SDR filter defeats comparison (his own words: "makes it hard to make
-- comparisons"). This query returns all 3 segments in one result set so Superblocks can facet
-- them side by side instead of filtering between them.
--
-- SAME-PERIOD SNAPSHOT, NOT A CAUSAL CHAIN -- each row is "how much volume was at this stage
-- during this period," not a claim that this period's activity caused this period's pipeline.
-- The narration/caption layer must say this explicitly (same non-negotiable framing rule as
-- the rest of this dashboard's insights layer -- never let a snapshot read as causation).
--
-- PIPELINE_CREATED REUSES sdr_activity_to_pipeline.sql'S ALREADY-VALIDATED SAME-MONTH FRAMING,
-- NOT A NEW LAG MODEL -- checked that file's header before building this: it already tested
-- SDR calls vs. New Logo pipeline created at 0-month and 1-month lag, live, very recently
-- (2026-08-04). Same month wins (MM/Ent r=0.63, SMB r=0.17, Strategic r=-0.45 unreliable/
-- 1-person sample) -- 1-month lag is weaker or negative in all three segments. Plausible reason
-- already documented there: a qualifying call is often the SAME event that gets an opportunity
-- created, not a lead-time input weeks earlier. Do not add a lag shift to this file without
-- new evidence contradicting that finding -- same rule, restated here so it isn't silently
-- reintroduced by whoever builds the next chart.
--
-- BOOKED VS. HELD -- confirmed live: FCT_CRM_MEETING.MEETING_STATUS already has exactly the 4
-- values needed (completed / scheduled / cancelled / no_show), no second join required.
-- "Booked" = every row (all statuses) created in the period -- "Held" = MEETING_STATUS =
-- 'completed'. Held will always be <= booked by construction.
--
-- INBOUND VS. OUTBOUND -- FCT_CRM_MEETING itself doesn't carry this (confirmed live, checked
-- its full column list -- no inbound/outbound field). Kevin confirmed where it actually lives:
-- EXTERNAL_DATA.POLYTOMIC.SALESFORCE_EVENT.INBOUND_MEETING__C. Joined via MEETING_ID = ID --
-- confirmed live, 100% match rate (3,646 of 3,646 meetings in a 3-month test window), safe
-- 1:1 join, no fan-out.
--
-- SDR POD MAPPING -- same sdr_segment CASE (TEAM_NAME = 'SMB SDRs' / 'MM/Enterprise SDRs' /
-- 'Strategic SDRs') as sdr_activity_to_pipeline.sql. STRATEGIC SDR HEADCOUNT = 1 PERSON (Louis
-- Trujillo, per that file's already-validated finding) -- carried forward here unchanged --
-- re-verify before presenting if headcount may have changed. `sdr_headcount` = COUNT DISTINCT
-- SDRs who logged at least one activity that month, not a static roster size, so a 1-person
-- column reads visibly differently from a multi-person one.
--
-- PIPELINE CREATED IS NEW LOGO ONLY, DELIBERATELY -- same reasoning as
-- sdr_activity_to_pipeline.sql: Expansion/Move In pipeline is an existing-account motion, not
-- something SDR outbound/inbound-qualifying work would plausibly source. Same DSMB exclusion
-- (Pattern B via DIM_CRM_ACCOUNT_HISTORY.PMC_ID) on pipeline_created.
--
-- PARTIAL CURRENT MONTH FLAGGED, NOT HIDDEN -- same bug class as the Funnel Diagnosis
-- incident and sdr_activity_to_pipeline.sql's own fix: `is_partial_month` marks the
-- still-forming current calendar month explicitly so a small in-progress number doesn't read
-- as a real collapse.
--
-- STRAY SEMICOLONS IN COMMENTS FIXED 2026-08-06 -- caught while pasting this file's
-- `pipeline` CTE into insights_forecast_decline_drivers.sql (Task 8, Debrief restructure):
-- 3 literal semicolons inside this header's prose (the same-month-framing line, the
-- "Booked"/"Held" line, and the Louis Trujillo line) broke the naive multi-statement
-- validation splitter (docs/superblocks-setup.md 4.18's own documented lesson, apparently
-- missed on this file when written down). Replaced with "--", this repo's own
-- prose-separator convention.

WITH months AS (
    SELECT DATEADD(month, -SEQ4(), DATE_TRUNC('month', CURRENT_DATE())) AS mo
    FROM TABLE(GENERATOR(ROWCOUNT => {{ LookbackMonths.value }} + 1))
),
pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
emp_dedup AS (
    SELECT EMPLOYEE_SK, EMAIL
    FROM FLEX.MART.DIM_EMPLOYEE_HISTORY
    WHERE SOURCE_SYSTEM = 'salesforce' AND IS_CURRENT = TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY UPDATED_AT_UTC DESC) = 1
),
user_dedup AS (
    SELECT EMAIL, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
emp AS (
    SELECT ed.EMPLOYEE_SK,
        CASE
            WHEN u.TEAM_NAME = 'SMB SDRs' THEN 'SMB'
            WHEN u.TEAM_NAME = 'MM/Enterprise SDRs' THEN 'MM/Ent'
            WHEN u.TEAM_NAME = 'Strategic SDRs' THEN 'Strategic'
            ELSE NULL
        END AS sdr_segment
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE())
),
activity AS (
    SELECT DATE_TRUNC('month', t.COMPLETED_AT_UTC) AS mo, e.sdr_segment AS segment,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'call', t.TASK_ID, NULL))  AS calls,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'email', t.TASK_ID, NULL)) AS emails,
        COUNT(DISTINCT t.EMPLOYEE_SK) AS sdr_headcount
    FROM FLEX.SALES.FCT_CRM_TASK t
    JOIN emp e ON t.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
    WHERE t.TASK_STATUS = 'completed'
      AND t.COMPLETED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, DATE_TRUNC('month', CURRENT_DATE()))
    GROUP BY 1, 2
),
meetings AS (
    SELECT
        DATE_TRUNC('month', m.CREATED_AT_UTC) AS mo,
        e.sdr_segment AS segment,
        COUNT(*)                                                    AS meetings_booked,
        SUM(IFF(m.MEETING_STATUS = 'completed', 1, 0))               AS meetings_held,
        SUM(IFF(m.MEETING_STATUS = 'completed' AND se.INBOUND_MEETING__C, 1, 0)) AS meetings_held_inbound
    FROM FLEX.SALES.FCT_CRM_MEETING m
    JOIN emp e ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
    LEFT JOIN EXTERNAL_DATA.POLYTOMIC.SALESFORCE_EVENT se ON m.MEETING_ID = se.ID
    WHERE m.CREATED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, DATE_TRUNC('month', CURRENT_DATE()))
    GROUP BY 1, 2
),
pipeline AS (
    SELECT
        mo.mo, e.ae_segment AS segment,
        COUNT(DISTINCT o.OPPORTUNITY_ID) AS pipeline_created
    FROM months mo
    JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o
        ON DATE_TRUNC('month', o.CREATED_AT_UTC) = mo.mo
       AND o.OPPORTUNITY_TYPE = 'New Logo'
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY oe ON o.OWNER_SK = oe.EMPLOYEE_SK AND oe.IS_CURRENT = TRUE
    LEFT JOIN user_dedup ou ON ou.EMAIL = oe.EMAIL
    LEFT JOIN (
        SELECT EMAIL,
            CASE
                WHEN TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
                WHEN TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND PARENT_TEAM = 'Mid Market +' THEN 'Strategic'
                WHEN TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
                ELSE NULL
            END AS ae_segment
        FROM user_dedup
    ) e ON e.EMAIL = ou.EMAIL
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE e.ae_segment IS NOT NULL
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
    GROUP BY 1, 2
)
SELECT
    mo.mo                                             AS month,
    COALESCE(a.segment, mt.segment, p.segment)         AS segment,
    COALESCE(a.calls, 0)                               AS calls,
    COALESCE(a.emails, 0)                              AS emails,
    COALESCE(a.calls, 0) + COALESCE(a.emails, 0)       AS activity_total,
    COALESCE(a.sdr_headcount, 0)                       AS sdr_headcount,
    COALESCE(mt.meetings_booked, 0)                    AS meetings_booked,
    COALESCE(mt.meetings_held, 0)                      AS meetings_held,
    DIV0(COALESCE(mt.meetings_held, 0), COALESCE(mt.meetings_booked, 0)) AS meetings_held_rate,
    COALESCE(mt.meetings_held_inbound, 0)              AS meetings_held_inbound,
    -- Added 2026-08-05, same clarity fix as sdr_activity_by_rep.sql -- explicit outbound
    -- count instead of making the reader subtract inbound from held themselves.
    COALESCE(mt.meetings_held, 0) - COALESCE(mt.meetings_held_inbound, 0) AS meetings_held_outbound,
    DIV0(COALESCE(mt.meetings_held_inbound, 0), COALESCE(mt.meetings_held, 0)) AS inbound_share_of_held,
    COALESCE(p.pipeline_created, 0)                    AS pipeline_created,
    mo.mo = DATE_TRUNC('month', CURRENT_DATE())        AS is_partial_month
FROM months mo
LEFT JOIN activity a ON a.mo = mo.mo
LEFT JOIN meetings mt ON mt.mo = mo.mo AND mt.segment = a.segment
LEFT JOIN pipeline p ON p.mo = mo.mo AND p.segment = COALESCE(a.segment, mt.segment)
WHERE COALESCE(a.segment, mt.segment, p.segment) IS NOT NULL
  {{#Segment.value}} AND COALESCE(a.segment, mt.segment, p.segment) = '{{Segment.value}}' {{/Segment.value}}
ORDER BY segment, month;
