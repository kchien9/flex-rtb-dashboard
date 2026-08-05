-- SDR Activity, by Rep -- drill-through underneath sdr_funnel_by_segment.sql. Same metrics,
-- grouped by individual SDR instead of segment/pod -- gated behind a click-through, not the
-- default view (same macro-first-then-micro placement principle as the rep leaderboard and
-- Debrief's individual-drivers tier).
--
-- DELIBERATELY NO pipeline_created COLUMN AT THIS GRAIN -- sdr_funnel_by_segment.sql's
-- pipeline_created is a SEGMENT-level correlation (SDR pod activity vs. AE-segment pipeline),
-- already explicit that it's not per-record attribution. Decomposing that down to "this
-- specific SDR sourced this much pipeline" would require the exact SDR_SK -> opportunity
-- resolution already confirmed live to work only ~11% of the time (see sdr_activity_to_
-- pipeline.sql's header). Showing a per-SDR pipeline number here would silently reintroduce
-- the fake-attribution problem this whole build was designed to avoid. If per-SDR pipeline
-- credit is ever wanted, it needs a real attribution fix first, not a query that just changes
-- the GROUP BY on a number that was never attributable in the first place.
--
-- Same sdr_segment pod mapping, same booked/held (MEETING_STATUS, no second join needed for
-- that part), same inbound join (SALESFORCE_EVENT.INBOUND_MEETING__C via MEETING_ID = ID) as
-- sdr_funnel_by_segment.sql. Same departure grace period.

WITH emp_dedup AS (
    SELECT EMPLOYEE_SK, EMAIL
    FROM FLEX.MART.DIM_EMPLOYEE_HISTORY
    WHERE SOURCE_SYSTEM = 'salesforce' AND IS_CURRENT = TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY UPDATED_AT_UTC DESC) = 1
),
user_dedup AS (
    SELECT EMAIL, FULL_NAME, TEAM_NAME, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
emp AS (
    SELECT ed.EMPLOYEE_SK, u.FULL_NAME AS rep,
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
    SELECT DATE_TRUNC('month', t.COMPLETED_AT_UTC) AS mo, e.rep, e.sdr_segment,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'call', t.TASK_ID, NULL))  AS calls,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'email', t.TASK_ID, NULL)) AS emails
    FROM FLEX.SALES.FCT_CRM_TASK t
    JOIN emp e ON t.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
    WHERE t.TASK_STATUS = 'completed'
      AND t.COMPLETED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, DATE_TRUNC('month', CURRENT_DATE()))
    GROUP BY 1, 2, 3
),
meetings AS (
    SELECT
        DATE_TRUNC('month', m.CREATED_AT_UTC) AS mo, e.rep, e.sdr_segment,
        COUNT(*)                                                    AS meetings_booked,
        SUM(IFF(m.MEETING_STATUS = 'completed', 1, 0))               AS meetings_held,
        SUM(IFF(m.MEETING_STATUS = 'completed' AND se.INBOUND_MEETING__C, 1, 0)) AS meetings_held_inbound
    FROM FLEX.SALES.FCT_CRM_MEETING m
    JOIN emp e ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.sdr_segment IS NOT NULL
    LEFT JOIN EXTERNAL_DATA.POLYTOMIC.SALESFORCE_EVENT se ON m.MEETING_ID = se.ID
    WHERE m.CREATED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, DATE_TRUNC('month', CURRENT_DATE()))
    GROUP BY 1, 2, 3
)
SELECT
    COALESCE(a.mo, mt.mo)                              AS month,
    COALESCE(a.rep, mt.rep)                             AS rep,
    COALESCE(a.sdr_segment, mt.sdr_segment)             AS segment,
    COALESCE(a.calls, 0)                                AS calls,
    COALESCE(a.emails, 0)                               AS emails,
    COALESCE(a.calls, 0) + COALESCE(a.emails, 0)        AS activity_total,
    COALESCE(mt.meetings_booked, 0)                     AS meetings_booked,
    COALESCE(mt.meetings_held, 0)                       AS meetings_held,
    DIV0(COALESCE(mt.meetings_held, 0), COALESCE(mt.meetings_booked, 0)) AS meetings_held_rate,
    COALESCE(mt.meetings_held_inbound, 0)               AS meetings_held_inbound,
    DIV0(COALESCE(mt.meetings_held_inbound, 0), COALESCE(mt.meetings_held, 0)) AS inbound_share_of_held
FROM activity a
FULL OUTER JOIN meetings mt ON a.mo = mt.mo AND a.rep = mt.rep
WHERE COALESCE(a.sdr_segment, mt.sdr_segment) IS NOT NULL
  {{#Segment.value}} AND COALESCE(a.sdr_segment, mt.sdr_segment) = '{{Segment.value}}' {{/Segment.value}}
ORDER BY segment, rep, month;
