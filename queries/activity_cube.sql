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
tasks AS (
    SELECT
        p.period,
        e.FULL_NAME AS rep,
        CASE
            WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN e.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN e.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'call', t.TASK_ID, NULL))  AS calls,
        COUNT(DISTINCT IFF(t.TASK_TYPE = 'email', t.TASK_ID, NULL)) AS emails
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_TASK t
        ON t.COMPLETED_AT_UTC BETWEEN p.start_date AND p.end_date AND t.TASK_STATUS = 'completed'
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON t.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
    GROUP BY 1, 2, 3
),
meets AS (
    SELECT
        p.period,
        e.FULL_NAME AS rep,
        CASE
            WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN e.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN e.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        COUNT(DISTINCT IFF(m.MEETING_SUBTYPE = 'Sales | Demo', m.MEETING_ID, NULL)) AS demos,
        COUNT(DISTINCT m.MEETING_ID)                                                AS meetings_total
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_MEETING m
        ON m.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date AND m.MEETING_STATUS = 'completed'
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
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
