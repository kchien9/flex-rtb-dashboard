-- Sales Cycle Time Trend -- blind spot #3 Kevin asked for: sales_cycle_time_by_segment.sql
-- already computes touch-to-close time, but only this-vs-last (2 periods) -- nothing checks
-- whether the cycle itself has been LENGTHENING over several months, an early signal of buyer
-- hesitancy or a harder market, distinct from win rate or volume. Same first_touch/rollout
-- logic as that file (reused verbatim, not re-derived), extended to a trailing multi-month
-- series with the same gaps-and-islands streak technique as the other scanners.
--
-- NEW LOGO ONLY, SCOPE NARROWED DELIBERATELY -- the original file's Expansion first_touch
-- needed a special AE-only restriction + anchor-to-previous-close fix (PSMs log more activity
-- on expansion-eligible accounts than any AE team -- see that file's header) specifically
-- because Expansion coverage is already thin (~15-62% by segment). Stacking a multi-month
-- streak requirement on top of that thin, deal-type-specific coverage would be noise on noise.
-- New Logo has the cleanest, highest-coverage first-touch definition (simple first-activity-
-- ever-on-the-account) -- kept to that scope here; extend to Expansion later only if this
-- proves useful and coverage supports it.
--
-- BOTH DIRECTIONS SURFACE -- a lengthening cycle is bad news (buyer hesitancy, harder market);
-- a shortening one is good news (more efficient selling) -- same "mix signal, not a decline-
-- only signal" reasoning as insights_mix_shift_scanner.sql.
--
-- MATERIALITY FLOOR ON DEAL COUNT, NOT JUST TOUCH COUNT -- sales_cycle_time_by_segment.sql's
-- own header already flags this repo's small-sample caveat (some segment/month combos had 1-6
-- deals) -- `{{ MinDealsFloor.value }}` (validate against real monthly deal counts per segment
-- before shipping) keeps a 2-deal month's median from counting toward a "trend."
--
-- BP MONTH, NOT CALENDAR -- same bug class as insights_declining_streaks.sql Part B and
-- insights_deal_size_trend.sql: bucketing CLOSED_AT_UTC by calendar month mislabels the last
-- few days of a BP month as belonging to the next one. Fixed to the standard BP-month IFF
-- formula.
--
-- GRANULARITY ADDED 2026-08-04 -- `{{ Granularity.value }}` = 'Month' | 'Quarter', same
-- DATE_TRUNC('quarter', bp_month) technique as the other scanners. Lookback widened from 12 to
-- 24 months (fixed, not scaled by a LookbackMonths param -- this file never had one) so Quarter
-- grain still has enough periods for a real streak.

WITH emp_dedup AS (
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
any_activity AS (
    SELECT CRM_ACCOUNT_SK, activity_date FROM (
        SELECT CRM_ACCOUNT_SK, COMPLETED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_TASK WHERE TASK_STATUS = 'completed'
        UNION ALL
        SELECT CRM_ACCOUNT_SK, STARTED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_MEETING WHERE MEETING_STATUS = 'completed'
    )
),
first_activity_ever AS (
    SELECT CRM_ACCOUNT_SK, MIN(activity_date) AS first_activity_date
    FROM any_activity
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
      AND o.CLOSED_AT_UTC >= DATEADD(month, -24, CURRENT_DATE())
),
with_touch AS (
    SELECT d.OPPORTUNITY_ID, d.segment_bucket, d.CLOSED_AT_UTC,
        IFF(DAY(d.CLOSED_AT_UTC) <= 4, DATE_TRUNC('month', d.CLOSED_AT_UTC), DATE_TRUNC('month', DATEADD(month, 1, d.CLOSED_AT_UTC))) AS bp_month,
        DATEDIFF(day, fa.first_activity_date, d.CLOSED_AT_UTC) AS days_touch_to_close
    FROM deals d
    LEFT JOIN first_activity_ever fa ON d.CRM_ACCOUNT_SK = fa.CRM_ACCOUNT_SK
    WHERE d.segment_bucket IS NOT NULL AND fa.first_activity_date IS NOT NULL
),
monthly AS (
    SELECT segment_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', bp_month), bp_month) AS period,
        MEDIAN(days_touch_to_close) AS median_days,
        COUNT(*) AS deals_with_touch
    FROM with_touch
    GROUP BY 1, 2
    HAVING deals_with_touch >= {{ MinDealsFloor.value }}
)
SELECT * FROM monthly ORDER BY segment_bucket, period;

-- Part B: lengthening/shortening streak, all segments scanned at once -- same gaps-and-islands
-- technique as insights_declining_streaks.sql, applied to median_days_touch_to_close.
WITH emp_dedup AS (
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
any_activity AS (
    SELECT CRM_ACCOUNT_SK, activity_date FROM (
        SELECT CRM_ACCOUNT_SK, COMPLETED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_TASK WHERE TASK_STATUS = 'completed'
        UNION ALL
        SELECT CRM_ACCOUNT_SK, STARTED_AT_UTC AS activity_date FROM FLEX.SALES.FCT_CRM_MEETING WHERE MEETING_STATUS = 'completed'
    )
),
first_activity_ever AS (
    SELECT CRM_ACCOUNT_SK, MIN(activity_date) AS first_activity_date
    FROM any_activity
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
      AND o.CLOSED_AT_UTC >= DATEADD(month, -24, CURRENT_DATE())
),
with_touch AS (
    SELECT d.OPPORTUNITY_ID, d.segment_bucket, d.CLOSED_AT_UTC,
        IFF(DAY(d.CLOSED_AT_UTC) <= 4, DATE_TRUNC('month', d.CLOSED_AT_UTC), DATE_TRUNC('month', DATEADD(month, 1, d.CLOSED_AT_UTC))) AS bp_month,
        DATEDIFF(day, fa.first_activity_date, d.CLOSED_AT_UTC) AS days_touch_to_close
    FROM deals d
    LEFT JOIN first_activity_ever fa ON d.CRM_ACCOUNT_SK = fa.CRM_ACCOUNT_SK
    WHERE d.segment_bucket IS NOT NULL AND fa.first_activity_date IS NOT NULL
),
monthly AS (
    SELECT segment_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', bp_month), bp_month) AS period,
        MEDIAN(days_touch_to_close) AS median_days, COUNT(*) AS deals_with_touch
    FROM with_touch
    GROUP BY 1, 2
    HAVING deals_with_touch >= {{ MinDealsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(median_days - LAG(median_days) OVER (PARTITION BY segment_bucket ORDER BY period)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY segment_bucket ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY segment_bucket ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT segment_bucket, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_month, MAX_BY(median_days, period) AS latest_median_days
    FROM with_group
    GROUP BY segment_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY segment_bucket)
)
SELECT segment_bucket, chg_sign AS direction, streak_len AS streak_months, latest_month, latest_median_days
FROM streaks
WHERE streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;
