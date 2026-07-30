-- Activities, by Team -- the middle drill level: activities_by_segment.sql (top) -> this
-- (middle) -> activity_vs_outcome_by_rep.sql filtered by Team (bottom). Same interaction
-- pattern Rolled-Out Units already uses (click a segment row, reveals team, reveals rep).
--
-- REBUILT 2026-07-30 -- first version of this file mixed AE Meetings with Pipeline Created/
-- Closed Won/Rolled-Out Units in one row. Kevin: "remove the whole table bc we cannot show
-- this causal chain at all. I just want segment then calls emails meetings demos." Even
-- without a causal narrative sentence, arranging activity and outcome columns left-to-right in
-- funnel order still visually implies a chain -- fixed by dropping every outcome column
-- entirely, not just the narrative text. This is now PURE activity: Calls/Emails/Meetings/
-- Demos, same 4 metrics as activities_by_segment.sql, just grouped by team_bucket instead of
-- segment_bucket. Outcomes live on Deals & Units / Pipeline, not here.
--
-- Calls/emails/meetings/demos are whoever logged them rolled up to team (no SDR-pod split
-- needed now that this isn't paired against AE-side outcomes) -- SDR pods are segment-scoped
-- in Salesforce anyway (no "Rory's SDRs" vs "Sebastian's SDRs"), so a team-level SDR-specific
-- cut still wouldn't be real even if this file wanted one.
--
-- Same dedup + departure-grace-period pattern as everywhere else in this repo.

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
            WHEN u.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN u.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN u.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN u.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND u.PARENT_TEAM = 'Mid Market +' THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE())
),
tasks AS (
    SELECT p.period, tm.team_bucket AS team,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'call', t.TASK_ID, NULL))  AS calls,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'email', t.TASK_ID, NULL)) AS emails
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_TASK t ON t.COMPLETED_AT_UTC BETWEEN p.start_date AND p.end_date AND t.TASK_STATUS = 'completed'
    JOIN team_map tm ON t.EMPLOYEE_SK = tm.EMPLOYEE_SK AND tm.team_bucket IS NOT NULL
    GROUP BY 1, 2
),
meets AS (
    SELECT p.period, tm.team_bucket AS team,
        COUNT(DISTINCT IFF(m.MEETING_SUBTYPE = 'Sales | Demo', m.MEETING_ID, NULL)) AS demos,
        COUNT(DISTINCT m.MEETING_ID)                                                 AS meetings
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_MEETING m ON m.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date AND m.MEETING_STATUS = 'completed'
    JOIN team_map tm ON m.EMPLOYEE_SK = tm.EMPLOYEE_SK AND tm.team_bucket IS NOT NULL
    GROUP BY 1, 2
)
SELECT
    COALESCE(tk.period, mt.period) AS period,
    COALESCE(tk.team, mt.team)      AS team,
    COALESCE(tk.calls, 0)           AS calls,
    COALESCE(tk.emails, 0)          AS emails,
    COALESCE(mt.meetings, 0)        AS meetings,
    COALESCE(mt.demos, 0)           AS demos
FROM tasks tk
FULL OUTER JOIN meets mt ON tk.period = mt.period AND tk.team = mt.team
{{#Segment.value}}
WHERE COALESCE(tk.team, mt.team) IN (
    SELECT team_bucket FROM (
        SELECT 'Brandon''s Team' AS team_bucket, 'MM/Ent' AS segment_bucket UNION ALL
        SELECT 'Sebastian''s Team', 'SMB' UNION ALL
        SELECT 'Rory''s Team', 'SMB' UNION ALL
        SELECT 'Dana''s Team', 'Strategic'
    ) WHERE segment_bucket = '{{Segment.value}}'
)
{{/Segment.value}}
ORDER BY team, period;
