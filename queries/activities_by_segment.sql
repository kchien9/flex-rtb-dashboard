-- Activities, by Segment -- Kevin, correcting the previous "Full Funnel" table: "remove the
-- whole table bc we cannot show this causal chain at all. I just want segment then calls
-- emails meetings demos. then clicking into the table opens up the team/rep level inline."
--
-- PURE ACTIVITY, NO OUTCOMES -- full_funnel_by_segment.sql (now superseded, not just
-- reframed) put SDR Calls/AE Meetings side by side with Pipeline Created/Closed Won/
-- Rolled-Out in one row. Even with the causal narrative text removed, arranging activity and
-- outcome columns left-to-right in funnel order still visually implies a chain. Fixed by
-- separating concerns entirely: this file is ONLY Calls/Emails/Meetings/Demos. Outcomes
-- (pipeline created, closed won, rolled out) already have their own home on Deals & Units and
-- Pipeline -- they don't need a second, activity-adjacent appearance here that invites reading
-- a causal story into the juxtaposition.
--
-- Top of the segment -> team -> rep drill (this file / activities_by_team.sql /
-- activity_vs_outcome_by_rep.sql -- see that file's header for why rep-level activity still
-- sits alongside outcome columns there specifically, a narrower and more deliberate case than
-- this segment-level table).
--
-- Calls/emails/meetings/demos are whoever logged them (SDR or AE alike) rolled up to segment --
-- NOT split by SDR-pod vs AE-pod the way full_funnel_by_segment.sql did (that split only
-- existed to support the now-removed activity-to-outcome comparison; a flat activity count
-- doesn't need it). Same dedup + departure-grace-period pattern as everywhere else in this
-- repo. segment_bucket here is the broader bucket (includes House Accounts) -- team_bucket
-- would exclude it, matching every other segment-level query in this repo.

WITH current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
bp_periods AS (
    SELECT 'this_month' AS period,
        DATEADD(day, 4, DATEADD(month, -1, bp_month_label)) AS start_date,
        LEAST(DATEADD(day, 3, bp_month_label), CURRENT_DATE()) AS end_date
    FROM current_bp
    UNION ALL
    SELECT 'last_month_full',
        DATEADD(day, 4, DATEADD(month, -2, bp_month_label)),
        DATEADD(day, 3, DATEADD(month, -1, bp_month_label))
    FROM current_bp
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
team_map AS (
    SELECT ed.EMPLOYEE_SK,
        CASE
            WHEN u.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN u.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND u.PARENT_TEAM = 'Mid Market +' THEN 'Strategic'
            WHEN u.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN u.TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE())
),
tasks AS (
    SELECT p.period, tm.segment_bucket,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'call', t.TASK_ID, NULL))  AS calls,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'email', t.TASK_ID, NULL)) AS emails
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_TASK t ON t.COMPLETED_AT_UTC BETWEEN p.start_date AND p.end_date AND t.TASK_STATUS = 'completed'
    JOIN team_map tm ON t.EMPLOYEE_SK = tm.EMPLOYEE_SK AND tm.segment_bucket IS NOT NULL
    GROUP BY 1, 2
),
meets AS (
    SELECT p.period, tm.segment_bucket,
        COUNT(DISTINCT IFF(m.MEETING_SUBTYPE = 'Sales | Demo', m.MEETING_ID, NULL)) AS demos,
        COUNT(DISTINCT m.MEETING_ID)                                                 AS meetings
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_MEETING m ON m.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date AND m.MEETING_STATUS = 'completed'
    JOIN team_map tm ON m.EMPLOYEE_SK = tm.EMPLOYEE_SK AND tm.segment_bucket IS NOT NULL
    GROUP BY 1, 2
)
SELECT
    COALESCE(tk.period, mt.period)          AS period,
    COALESCE(tk.segment_bucket, mt.segment_bucket) AS segment_bucket,
    COALESCE(tk.calls, 0)                   AS calls,
    COALESCE(tk.emails, 0)                  AS emails,
    COALESCE(mt.meetings, 0)                AS meetings,
    COALESCE(mt.demos, 0)                   AS demos
FROM tasks tk
FULL OUTER JOIN meets mt ON tk.period = mt.period AND tk.segment_bucket = mt.segment_bucket
ORDER BY segment_bucket, period;
