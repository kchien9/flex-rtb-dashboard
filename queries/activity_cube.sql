-- Activity Cube -- Calls, Emails, Meetings, and Demos together. Per Kevin: "lets include
-- emails and calls to meetings since those are all the activities we track" -- this is the
-- upstream end of the funnel (activity -> pipeline -> closed -> units), so a "why was this
-- week slow" question should be answerable by looking here first, not just at Meetings alone.
--
-- SOURCES, confirmed live 2026-07-28:
--   Calls, Emails  <- FLEX.SALES.FCT_CRM_TASK, TASK_TYPE = 'call'/'email', TASK_STATUS = 'completed'
--   Meetings, Demos <- FLEX.SALES.FCT_CRM_MEETING, MEETING_STATUS = 'completed'.
--     Demos = MEETING_SUBTYPE = 'Sales | Demo' specifically (per Kevin: "how many completed
--     demos AEs do" -- a real, clean subtype, not all meetings are demos. Validated live:
--     "Sales | Demo" is by far the largest non-null subtype, 658 in a trailing 2mo window).
--
-- JOIN FAN-OUT BUG CAUGHT WHILE BUILDING THIS -- same class of bug as insights_mix_shift.sql's
-- header writeup. First draft joined FCT_CRM_TASK to FCT_CRM_MEETING directly on
-- EMPLOYEE_SK (to get both in one pass) -- that's a cross join between every task row and
-- every meeting row for the same rep in the same period, inflating counts by 10-50x (one
-- test showed 24,208 "calls" for a bucket that should have shown ~300). FIX: aggregate tasks
-- and meetings in SEPARATE CTEs first, each down to (period, team_bucket) grain, THEN join
-- the two aggregates together -- never join two fact tables at the raw-row grain when you
-- only need a combined aggregate, always aggregate first.
--
-- team_bucket: same mapping as performance_cube.sql -- built off DIM_EMPLOYEE_HISTORY.
-- TEAM_NAME (rep-grain), same known data-quality caveat (Dana Finch shows as "Enterprise AE
-- Manager" in some rows, not a clean pod name -- her true activity may be undercounted here).
--
-- INACTIVE/CROSS-TEAM LEAKAGE FIX (2026-07-29) -- same root cause and same fix as
-- activity_vs_outcome_by_rep.sql's header (read that for the full writeup): DIM_EMPLOYEE_HISTORY
-- has no active/inactive concept and carries multiple IS_CURRENT rows per person across source
-- systems. team_map below dedupes to the Salesforce-sourced row (confirmed 100% of this file's
-- EMPLOYEE_SK values resolve there), joins to deduped STG_SALESFORCE__USER for real TEAM_NAME/
-- PARENT_TEAM/IS_ACTIVE/LAST_LOGIN_AT_UTC, requires PARENT_TEAM='Mid Market +' for the
-- Strategic pod (drops Saba Obaid-style stray records), and applies the standard
-- {{ GraceMonths.value }} (default 2) departure grace period.

WITH current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
bp_periods AS (
    SELECT 'this_month' AS period,
        DATEADD(day, 4, DATEADD(month, -1, bp_month_label))                                AS start_date,
        LEAST(DATEADD(day, 3, bp_month_label), CURRENT_DATE())                              AS end_date
    FROM current_bp
    UNION ALL
    SELECT 'last_month_mtd',
        DATEADD(day, 4, DATEADD(month, -2, bp_month_label)),
        DATEADD(day,
            DATEDIFF(day, DATEADD(day,4,DATEADD(month,-1,bp_month_label)), LEAST(DATEADD(day,3,bp_month_label), CURRENT_DATE())),
            DATEADD(day, 4, DATEADD(month, -2, bp_month_label)))
    FROM current_bp
    UNION ALL
    SELECT 'this_week', DATE_TRUNC('week', CURRENT_DATE()), CURRENT_DATE() FROM current_bp
    UNION ALL
    SELECT 'last_week_wtd',
        DATE_TRUNC('week', CURRENT_DATE()) - 7,
        (DATE_TRUNC('week', CURRENT_DATE()) - 7) + DATEDIFF(day, DATE_TRUNC('week', CURRENT_DATE()), CURRENT_DATE())
    FROM current_bp
),
emp_dedup AS (
    SELECT EMPLOYEE_SK, EMAIL
    FROM FLEX.MART.DIM_EMPLOYEE_HISTORY
    WHERE SOURCE_SYSTEM = 'salesforce' AND IS_CURRENT = TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY UPDATED_AT_UTC DESC) = 1
),
user_dedup AS (
    SELECT EMAIL, FULL_NAME, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
team_map AS (
    SELECT ed.EMPLOYEE_SK, u.FULL_NAME,
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
    SELECT
        p.period,
        m.FULL_NAME AS rep,
        m.team_bucket,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'call', t.TASK_ID, NULL))  AS calls,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'email', t.TASK_ID, NULL)) AS emails
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_TASK t
        ON t.COMPLETED_AT_UTC BETWEEN p.start_date AND p.end_date AND t.TASK_STATUS = 'completed'
    JOIN team_map m ON t.EMPLOYEE_SK = m.EMPLOYEE_SK AND m.team_bucket IS NOT NULL
    GROUP BY 1, 2, 3
),
meets AS (
    SELECT
        p.period,
        m.FULL_NAME AS rep,
        m.team_bucket,
        COUNT(DISTINCT IFF(mt.MEETING_SUBTYPE = 'Sales | Demo', mt.MEETING_ID, NULL)) AS demos,
        COUNT(DISTINCT mt.MEETING_ID)                                                 AS meetings_total
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_MEETING mt
        ON mt.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date AND mt.MEETING_STATUS = 'completed'
    JOIN team_map m ON mt.EMPLOYEE_SK = m.EMPLOYEE_SK AND m.team_bucket IS NOT NULL
    GROUP BY 1, 2, 3
)
SELECT
    COALESCE(tk.period, mt.period)             AS period,
    COALESCE(tk.rep, mt.rep)                    AS rep,
    COALESCE(tk.team_bucket, mt.team_bucket)    AS team_bucket,
    COALESCE(tk.calls, 0)                       AS calls,
    COALESCE(tk.emails, 0)                      AS emails,
    COALESCE(mt.meetings_total, 0)              AS meetings,
    COALESCE(mt.demos, 0)                       AS demos
FROM tasks tk
FULL OUTER JOIN meets mt ON tk.period = mt.period AND tk.rep = mt.rep
WHERE COALESCE(tk.team_bucket, mt.team_bucket) IS NOT NULL
  {{#Team.value}} AND COALESCE(tk.team_bucket, mt.team_bucket) = '{{Team.value}}' {{/Team.value}}
ORDER BY 1, 3, 2;
