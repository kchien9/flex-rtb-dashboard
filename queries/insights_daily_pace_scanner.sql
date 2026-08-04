-- Daily Pace Scanner -- Kevin: "does it make sense to incorporate trending averages across
-- all dimensions? like units today were below the 7 day trending avg." Real, additive
-- question -- this catches something insights_declining_streaks.sql's BP-month grain
-- genuinely cannot see: a sharp day-to-day slowdown happening RIGHT NOW, before it's had time
-- to show up as a monthly decline streak.
--
-- WEEK-OVER-WEEK TRAILING AVERAGE, NOT "TODAY VS. 7-DAY AVERAGE" -- checked live before
-- writing this: rolled-out units have a strong, real weekly rhythm (confirmed on
-- rolled_out_units_daily_trend.sql already) -- weekends (2026-07-19, 07-25, 07-26, 08-01,
-- 08-02 in the pull checked live) are consistently near-zero. Comparing a single day against
-- a 7-day trailing average would flag every single weekend as "below average," which is
-- meaningless noise, not a real pace signal. Fixed by comparing two LIKE-FOR-LIKE 7-day
-- windows instead -- the trailing 7 days ending today vs. the 7 days before that -- both
-- windows contain the same weekday/weekend mix, so the comparison isolates a real pace change,
-- not the calendar rhythm this data already has.
--
-- Same gaps-and-islands-adjacent pattern as insights_declining_streaks.sql, but simpler --
-- just one delta per entity (this week's pace vs. last week's), not a multi-period streak,
-- since day-level data is too short-window for a meaningful multi-week streak requirement.
-- Materiality floor on the PRIOR week's average (not the current one) so a real, currently-
-- active team/segment/MSP dropping to near-zero still gets caught -- flooring on the current
-- week would hide exactly the cases most worth flagging.

-- Part A: by team.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    WHERE s.ROLLOUT_DATE IS NOT NULL AND (s.IS_NEW_INTEGRATED OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER)
),
daily AS (
    SELECT b.team_bucket, b.ROLLOUT_DATE AS day, SUM(b.PROPERTY_UNIT_COUNT) AS units
    FROM base b
    LEFT JOIN pmc_size p ON b.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND b.team_bucket IS NOT NULL
      AND b.ROLLOUT_DATE >= DATEADD(day, -13, CURRENT_DATE())
    GROUP BY 1, 2
),
windows AS (
    SELECT team_bucket,
        AVG(IFF(day >= DATEADD(day, -6, CURRENT_DATE()), units, NULL)) AS avg_last_7d,
        AVG(IFF(day < DATEADD(day, -6, CURRENT_DATE()), units, NULL)) AS avg_prior_7d
    FROM daily
    GROUP BY 1
)
SELECT team_bucket,
    ROUND(avg_last_7d, 0) AS avg_last_7d,
    ROUND(avg_prior_7d, 0) AS avg_prior_7d,
    DIV0(avg_last_7d - avg_prior_7d, avg_prior_7d) AS pct_change
FROM windows
WHERE avg_prior_7d >= {{ MinDailyAvgFloor.value }}
  AND DIV0(avg_last_7d - avg_prior_7d, avg_prior_7d) <= -{{ MinPctDropThreshold.value }}
ORDER BY pct_change ASC;

-- Part B: by segment.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    WHERE s.ROLLOUT_DATE IS NOT NULL AND (s.IS_NEW_INTEGRATED OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER)
),
daily AS (
    SELECT b.segment_bucket, b.ROLLOUT_DATE AS day, SUM(b.PROPERTY_UNIT_COUNT) AS units
    FROM base b
    LEFT JOIN pmc_size p ON b.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND b.segment_bucket IS NOT NULL
      AND b.ROLLOUT_DATE >= DATEADD(day, -13, CURRENT_DATE())
    GROUP BY 1, 2
),
windows AS (
    SELECT segment_bucket,
        AVG(IFF(day >= DATEADD(day, -6, CURRENT_DATE()), units, NULL)) AS avg_last_7d,
        AVG(IFF(day < DATEADD(day, -6, CURRENT_DATE()), units, NULL)) AS avg_prior_7d
    FROM daily
    GROUP BY 1
)
SELECT segment_bucket,
    ROUND(avg_last_7d, 0) AS avg_last_7d,
    ROUND(avg_prior_7d, 0) AS avg_prior_7d,
    DIV0(avg_last_7d - avg_prior_7d, avg_prior_7d) AS pct_change
FROM windows
WHERE avg_prior_7d >= {{ MinDailyAvgFloor.value }}
  AND DIV0(avg_last_7d - avg_prior_7d, avg_prior_7d) <= -{{ MinPctDropThreshold.value }}
ORDER BY pct_change ASC;

-- Part C: by MSP.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT s.*
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    WHERE s.ROLLOUT_DATE IS NOT NULL AND (s.IS_NEW_INTEGRATED OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER)
),
daily AS (
    SELECT COALESCE(b.PMS, 'Not Set') AS msp, b.ROLLOUT_DATE AS day, SUM(b.PROPERTY_UNIT_COUNT) AS units
    FROM base b
    LEFT JOIN pmc_size p ON b.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND b.ROLLOUT_DATE >= DATEADD(day, -13, CURRENT_DATE())
    GROUP BY 1, 2
),
windows AS (
    SELECT msp,
        AVG(IFF(day >= DATEADD(day, -6, CURRENT_DATE()), units, NULL)) AS avg_last_7d,
        AVG(IFF(day < DATEADD(day, -6, CURRENT_DATE()), units, NULL)) AS avg_prior_7d
    FROM daily
    GROUP BY 1
)
SELECT msp,
    ROUND(avg_last_7d, 0) AS avg_last_7d,
    ROUND(avg_prior_7d, 0) AS avg_prior_7d,
    DIV0(avg_last_7d - avg_prior_7d, avg_prior_7d) AS pct_change
FROM windows
WHERE avg_prior_7d >= {{ MinDailyAvgFloor.value }}
  AND DIV0(avg_last_7d - avg_prior_7d, avg_prior_7d) <= -{{ MinPctDropThreshold.value }}
ORDER BY pct_change ASC;
