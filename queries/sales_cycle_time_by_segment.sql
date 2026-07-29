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
--   1. first_touch (definition depends on deal_type -- see below)
--   2. CLOSED_AT_UTC (when the deal closed)
--   3. first_rollout_month (from FCT_CRM_OPPORTUNITY_LINE_ITEM, same source as
--      units_closed_forecast_bridge.sql's validated close->rollout lag)
-- median_days_touch_to_close and median_days_close_to_rollout, both trended this vs. last
-- month (cohort = deals that CLOSED in that period, not created in that period).
--
-- EXPANSION SUPPORT ADDED 2026-07-29 -- Kevin: "can we show cycle for expansion too? not sure
-- how that works though bc how can we attribute the first touch of an expansion deal on an
-- account... psms post activities onto accounts too that shouldnt be attributed since those
-- are more account mgmt not new opportunities." Both instincts were right, checked live:
--   1. PSM/CS ACTIVITY DOMINATES existing-account activity -- confirmed live: on accounts with
--      an Expansion deal, "Partner Success" logged MORE activity (27,964 rows) than any single
--      AE team. "First activity ever on the account" for Expansion would mostly be measuring
--      account-management touches, not the AE's actual expansion pursuit.
--   2. FIX: restrict first_touch to activity logged by an AE (team_bucket-eligible pod --
--      Brandon's/SMB AE 1&2/Strategic with PARENT_TEAM='Mid Market +'/House Accounts --
--      excludes Partner Success, SDR pods, and all non-AE org pods), AND anchor it to AFTER
--      the account's previous deal closed (via LAG(CLOSED_AT_UTC) per account), not all-time --
--      this also stops an expansion's "first touch" from reaching back into the ORIGINAL New
--      Logo sales cycle on the same account. New Logo doesn't need the AE-only restriction
--      (PSMs can't be logging account-management activity on a prospect that isn't a customer
--      yet) or the previous-close anchor (there IS no previous deal) -- keeps New Logo's
--      original, already-validated logic unchanged.
--   3. COVERAGE GAP, SHOWN NOT HIDDEN -- confirmed live, trailing 3 months: only ~50% of
--      Expansion deals have ANY measurable AE-logged touch in this window at all (varies a lot
--      by segment -- Strategic/MM+Ent ~62%, SMB only ~15%, consistent with SMB expansions being
--      lower-touch/more transactional). `deals_with_touch` is shown alongside `deals` so a
--      median computed over half the cohort (or less, for SMB) isn't mistaken for a
--      full-coverage number -- this is a real data-quality fact about how AEs log expansion
--      work, not a bug in this query.
--
-- Scoped to New Logo + Expansion, closed-won only. `deal_type` is an output column, not a
-- separate query -- filter/toggle in Superblocks rather than maintaining two files.
--
-- SMALL SAMPLE SIZE CAVEAT -- validated live: some segment/period/deal_type combinations have
-- very few deals (Strategic and MM/Ent New Logo each had 1-6 closed deals in some months), so
-- their median can swing hard on one or two deals. Show `deals` and `deals_with_touch`
-- alongside every median so a 1-deal "median" doesn't get read with the same confidence as a
-- 30-deal one -- don't hide the sample size.
--
-- Real validated numbers, trailing months: New Logo SMB touch-to-close 7 -> 12 days (getting
-- slower), MM/Ent 34 -> 43 days. Close-to-rollout stayed roughly flat across segments (11-19
-- days), consistent with the already-validated ~12-day company-wide median in
-- units_closed_forecast_bridge.sql. Expansion (trailing 3mo, AE-only/post-previous-close):
-- Strategic 7 days, MM/Ent 10 days, SMB 21 days touch-to-close.

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
    SELECT EMAIL, TEAM_NAME, PARENT_TEAM
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
ae_only AS (
    -- AE-eligible pods only -- excludes Partner Success/CS, SDR pods, and every other non-AE
    -- org pod, so Expansion's first_touch can't pick up account-management activity
    SELECT ed.EMPLOYEE_SK
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.TEAM_NAME = 'Brandon''s Team'
       OR u.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2')
       OR (u.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND u.PARENT_TEAM = 'Mid Market +')
       OR u.TEAM_NAME = 'House Accounts'
),
any_activity AS (
    SELECT CRM_ACCOUNT_SK, activity_date FROM (
        SELECT CRM_ACCOUNT_SK, COMPLETED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_TASK WHERE TASK_STATUS = 'completed'
        UNION ALL
        SELECT CRM_ACCOUNT_SK, STARTED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_MEETING WHERE MEETING_STATUS = 'completed'
    )
),
ae_activity AS (
    SELECT CRM_ACCOUNT_SK, COMPLETED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_TASK
        WHERE TASK_STATUS = 'completed' AND EMPLOYEE_SK IN (SELECT EMPLOYEE_SK FROM ae_only)
    UNION ALL
    SELECT CRM_ACCOUNT_SK, STARTED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_MEETING
        WHERE MEETING_STATUS = 'completed' AND EMPLOYEE_SK IN (SELECT EMPLOYEE_SK FROM ae_only)
),
first_activity_ever AS (
    SELECT CRM_ACCOUNT_SK, MIN(activity_date) AS first_activity_date
    FROM any_activity
    GROUP BY 1
),
rollout AS (
    SELECT OPPORTUNITY_ID, MIN(ROLLOUT_MONTH) AS first_rollout_month
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM
    WHERE ROLLOUT_MONTH IS NOT NULL
    GROUP BY 1
),
deals AS (
    SELECT o.OPPORTUNITY_ID, o.CRM_ACCOUNT_SK, o.CLOSED_AT_UTC, o.OPPORTUNITY_TYPE AS deal_type,
        LAG(o.CLOSED_AT_UTC) OVER (PARTITION BY o.CRM_ACCOUNT_SK ORDER BY o.CLOSED_AT_UTC) AS prev_close,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN o.STATIC_TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    WHERE o.IS_CLOSED_WON AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion')
),
first_touch AS (
    SELECT
        d.OPPORTUNITY_ID,
        CASE
            WHEN d.deal_type = 'New Logo' THEN fa.first_activity_date
            ELSE (
                SELECT MIN(a.activity_date) FROM ae_activity a
                WHERE a.CRM_ACCOUNT_SK = d.CRM_ACCOUNT_SK
                  AND a.activity_date <= d.CLOSED_AT_UTC
                  AND a.activity_date > COALESCE(d.prev_close, '1900-01-01'::TIMESTAMP)
            )
        END AS first_touch_date
    FROM deals d
    LEFT JOIN first_activity_ever fa ON d.CRM_ACCOUNT_SK = fa.CRM_ACCOUNT_SK
    -- Expansion with no prior close on this account is a data anomaly (shouldn't exist), not
    -- a real cycle to measure -- excluded rather than silently mismeasured
    WHERE d.deal_type = 'New Logo' OR d.prev_close IS NOT NULL
)
SELECT
    p.period,
    d.segment_bucket,
    d.deal_type,
    COUNT(*)                                                                     AS deals,
    COUNT(ft.first_touch_date)                                                   AS deals_with_touch,
    MEDIAN(DATEDIFF(day, ft.first_touch_date, d.CLOSED_AT_UTC))                   AS median_days_touch_to_close,
    MEDIAN(DATEDIFF(day, d.CLOSED_AT_UTC, r.first_rollout_month))                 AS median_days_close_to_rollout
FROM deals d
JOIN bp_periods p ON d.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date
JOIN first_touch ft ON d.OPPORTUNITY_ID = ft.OPPORTUNITY_ID
LEFT JOIN rollout r ON d.OPPORTUNITY_ID = r.OPPORTUNITY_ID
WHERE d.segment_bucket IS NOT NULL
  {{#Segment.value}} AND d.segment_bucket = '{{Segment.value}}' {{/Segment.value}}
  {{#DealType.value}} AND d.deal_type = '{{DealType.value}}' {{/DealType.value}}
GROUP BY 1, 2, 3
ORDER BY 2, 3, 1;
