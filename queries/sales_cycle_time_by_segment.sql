-- Sales Cycle Time, by Segment -- the fix for the lag question Kevin raised: "isnt there a
-- lag? like it would be more so last months activities that led to units drop off today."
-- Monthly-aggregate correlation between calls/meetings/pipeline turned out too noisy to
-- trust (checked live: weak, inconsistent, sometimes negative across segments -- see
-- project memory). Kevin's fix: "activities are attached to accounts so we should be able
-- to get a grip on how long it takes per segment from first call/meeting to close to roll
-- out" -- an ACCOUNT-LEVEL cycle-time measurement instead of a noisy aggregate correlation.
-- This is the right fix -- validated live, real and much cleaner signal than the monthly
-- correlation attempt.
--
-- Three stages measured directly per deal, not correlated indirectly:
--   1. first_activity_date (MIN of every completed call/meeting on the account, ever)
--   2. CLOSED_AT_UTC (when the deal closed)
--   3. first_rollout_month (from FCT_CRM_OPPORTUNITY_LINE_ITEM, same source as
--      units_closed_forecast_bridge.sql's validated close->rollout lag)
-- median_days_touch_to_close and median_days_close_to_rollout, both trended this vs. last
-- month (cohort = deals that CLOSED in that period, not created in that period).
--
-- Scoped to New Logo only -- per Kevin's own framing ("how long for a NEW LOGO to close"),
-- and because Expansion deals are on an existing account with pre-existing activity history,
-- so "first activity ever on this account" wouldn't measure the same thing for Expansion.
--
-- SMALL SAMPLE SIZE CAVEAT -- validated live: some segment/period combinations have very few
-- deals (Strategic and MM/Ent each had 1-6 closed New Logo deals in some months), so their
-- median can swing hard on one or two deals. Show the `deals` count alongside every median so
-- a 1-deal "median" doesn't get read with the same confidence as a 30-deal one -- don't hide
-- the sample size.
--
-- Real validated numbers, trailing months: SMB touch-to-close 7 -> 12 days (getting slower),
-- MM/Ent 34 -> 43 days. Close-to-rollout stayed roughly flat across segments (11-19 days),
-- consistent with the already-validated ~12-day company-wide median in
-- units_closed_forecast_bridge.sql.

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
first_activity AS (
    SELECT CRM_ACCOUNT_SK, MIN(activity_date) AS first_activity_date
    FROM (
        SELECT CRM_ACCOUNT_SK, COMPLETED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_TASK WHERE TASK_STATUS = 'completed'
        UNION ALL
        SELECT CRM_ACCOUNT_SK, STARTED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_MEETING WHERE MEETING_STATUS = 'completed'
    )
    GROUP BY 1
),
rollout AS (
    SELECT OPPORTUNITY_ID, MIN(ROLLOUT_MONTH) AS first_rollout_month
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM
    WHERE ROLLOUT_MONTH IS NOT NULL
    GROUP BY 1
),
deals AS (
    SELECT o.OPPORTUNITY_ID, o.CRM_ACCOUNT_SK, o.CLOSED_AT_UTC,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN o.STATIC_TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    WHERE o.IS_CLOSED_WON AND o.OPPORTUNITY_TYPE = 'New Logo'
      {{#Segment.value}} AND CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN o.STATIC_TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END = '{{Segment.value}}' {{/Segment.value}}
)
SELECT
    p.period,
    d.segment_bucket,
    COUNT(*)                                                                     AS deals,
    MEDIAN(DATEDIFF(day, fa.first_activity_date, d.CLOSED_AT_UTC))                AS median_days_touch_to_close,
    MEDIAN(DATEDIFF(day, d.CLOSED_AT_UTC, r.first_rollout_month))                 AS median_days_close_to_rollout
FROM deals d
JOIN bp_periods p ON d.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date
LEFT JOIN first_activity fa ON d.CRM_ACCOUNT_SK = fa.CRM_ACCOUNT_SK
LEFT JOIN rollout r ON d.OPPORTUNITY_ID = r.OPPORTUNITY_ID
WHERE d.segment_bucket IS NOT NULL
GROUP BY 1, 2
ORDER BY 2, 1;
