-- Rolled-Out Units, by Segment + Rep Drill -- Kevin: "i clicked this week and this is showing
-- this bp month. can we make this update for time filter above?" This is a separate,
-- dedicated build for THIS specific chart (segment total -> click -> rep breakdown), NOT a
-- retrofit of rolled_out_units_cube.sql itself -- that file is shared with the MSP tab and
-- Segment x MSP view, which stay on the existing BP-month basis; scoping this narrower avoids
-- touching working charts that don't need Week/Quarter granularity.
--
-- Same real finding that motivated this file: Kevin caught a rep-level number that didn't look
-- right (Cory Baach showing 75,647 units) -- checked live, his real single-BP-month totals are
-- 19K-38K depending on the month, nowhere near 75,647 (closer to 2-3 months summed). That
-- number was coming from the OLD BP-month-matching chart mislabeled under "This Week" -- this
-- file fixes both problems at once by rebuilding on ROLLOUT_DATE ranges (real day-level
-- precision, same discovery as rolled_out_units_daily_trend.sql) so "This Week" actually means
-- one calendar week's real rollouts, not a multi-month BP figure under a wrong label.
--
-- Same {{ Granularity.value }} = 'Week' | 'Month' | 'Quarter' pattern as activities_by_
-- segment.sql -- returns only the 2 relevant rows itself (this_period/last_period), pacing-
-- matched. NOTE: "Month" and "Quarter" here use ROLLOUT_DATE ranges aligned to BP-month
-- boundaries (not calendar month), so they still reconcile with the BP-month-based headline
-- figures elsewhere in this repo for those two granularities specifically -- only "Week" is
-- newly possible at all, since no BP-week concept exists (same note as performance_cube.sql's
-- header on why week stays calendar-based everywhere in this repo).
--
-- Same DSMB exclusion (PMC current live units > 750) and departure-grace-period rep-status
-- pattern as rep_leaderboard.sql.

-- Part A: segment totals
WITH current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
bp_periods AS (
    SELECT 'this_period' AS period,
        DATEADD(day, 4, DATEADD(month, -1, bp_month_label)) AS start_date,
        LEAST(DATEADD(day, 3, bp_month_label), CURRENT_DATE()) AS end_date
    FROM current_bp WHERE '{{ Granularity.value }}' = 'Month'
    UNION ALL
    SELECT 'last_period',
        DATEADD(day, 4, DATEADD(month, -2, bp_month_label)),
        DATEADD(day,
            DATEDIFF(day, DATEADD(day,4,DATEADD(month,-1,bp_month_label)), LEAST(DATEADD(day,3,bp_month_label), CURRENT_DATE())),
            DATEADD(day, 4, DATEADD(month, -2, bp_month_label)))
    FROM current_bp WHERE '{{ Granularity.value }}' = 'Month'
    UNION ALL
    SELECT 'this_period',
        DATEADD(day, 4, DATEADD(month, -1, DATE_TRUNC('quarter', bp_month_label))),
        LEAST(DATEADD(day, 3, DATEADD(month, 2, DATE_TRUNC('quarter', bp_month_label))), CURRENT_DATE())
    FROM current_bp WHERE '{{ Granularity.value }}' = 'Quarter'
    UNION ALL
    SELECT 'last_period',
        DATEADD(day, 4, DATEADD(month, -4, DATE_TRUNC('quarter', bp_month_label))),
        DATEADD(day,
            DATEDIFF(day, DATEADD(day,4,DATEADD(month,-1,DATE_TRUNC('quarter', bp_month_label))),
                          LEAST(DATEADD(day,3,DATEADD(month,2,DATE_TRUNC('quarter', bp_month_label))), CURRENT_DATE())),
            DATEADD(day, 4, DATEADD(month, -4, DATE_TRUNC('quarter', bp_month_label))))
    FROM current_bp WHERE '{{ Granularity.value }}' = 'Quarter'
    UNION ALL
    SELECT 'this_period', DATE_TRUNC('week', CURRENT_DATE()), CURRENT_DATE()
    FROM current_bp WHERE '{{ Granularity.value }}' = 'Week'
    UNION ALL
    SELECT 'last_period',
        DATE_TRUNC('week', CURRENT_DATE()) - 7,
        (DATE_TRUNC('week', CURRENT_DATE()) - 7) + DATEDIFF(day, DATE_TRUNC('week', CURRENT_DATE()), CURRENT_DATE())
    FROM current_bp WHERE '{{ Granularity.value }}' = 'Week'
),
pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT
        s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IS NULL THEN 'Not Set'
            ELSE NULL
        END AS segment_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    WHERE s.IS_NEW_INTEGRATED = TRUE AND s.ROLLOUT_DATE IS NOT NULL
)
SELECT
    p.period,
    b.segment_bucket,
    SUM(b.PROPERTY_UNIT_COUNT)      AS units,
    COUNT(DISTINCT b.PROPERTY_ID)    AS properties
FROM bp_periods p
JOIN base b ON b.ROLLOUT_DATE BETWEEN p.start_date AND p.end_date
LEFT JOIN pmc_size pm ON b.PMC_ID = pm.PMC_ID
WHERE (pm.pmc_current_units IS NULL OR pm.pmc_current_units > 750)
  AND b.segment_bucket IS NOT NULL
  {{#Segment.value}} AND b.segment_bucket = '{{Segment.value}}' {{/Segment.value}}
GROUP BY 1, 2
ORDER BY segment_bucket, period;

-- Part B: rep drill within a segment -- requires {{ Segment.value }} to be set.
WITH current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
bp_periods AS (
    SELECT 'this_period' AS period,
        DATEADD(day, 4, DATEADD(month, -1, bp_month_label)) AS start_date,
        LEAST(DATEADD(day, 3, bp_month_label), CURRENT_DATE()) AS end_date
    FROM current_bp WHERE '{{ Granularity.value }}' = 'Month'
    UNION ALL
    SELECT 'last_period',
        DATEADD(day, 4, DATEADD(month, -2, bp_month_label)),
        DATEADD(day,
            DATEDIFF(day, DATEADD(day,4,DATEADD(month,-1,bp_month_label)), LEAST(DATEADD(day,3,bp_month_label), CURRENT_DATE())),
            DATEADD(day, 4, DATEADD(month, -2, bp_month_label)))
    FROM current_bp WHERE '{{ Granularity.value }}' = 'Month'
    UNION ALL
    SELECT 'this_period',
        DATEADD(day, 4, DATEADD(month, -1, DATE_TRUNC('quarter', bp_month_label))),
        LEAST(DATEADD(day, 3, DATEADD(month, 2, DATE_TRUNC('quarter', bp_month_label))), CURRENT_DATE())
    FROM current_bp WHERE '{{ Granularity.value }}' = 'Quarter'
    UNION ALL
    SELECT 'last_period',
        DATEADD(day, 4, DATEADD(month, -4, DATE_TRUNC('quarter', bp_month_label))),
        DATEADD(day,
            DATEDIFF(day, DATEADD(day,4,DATEADD(month,-1,DATE_TRUNC('quarter', bp_month_label))),
                          LEAST(DATEADD(day,3,DATEADD(month,2,DATE_TRUNC('quarter', bp_month_label))), CURRENT_DATE())),
            DATEADD(day, 4, DATEADD(month, -4, DATE_TRUNC('quarter', bp_month_label))))
    FROM current_bp WHERE '{{ Granularity.value }}' = 'Quarter'
    UNION ALL
    SELECT 'this_period', DATE_TRUNC('week', CURRENT_DATE()), CURRENT_DATE()
    FROM current_bp WHERE '{{ Granularity.value }}' = 'Week'
    UNION ALL
    SELECT 'last_period',
        DATE_TRUNC('week', CURRENT_DATE()) - 7,
        (DATE_TRUNC('week', CURRENT_DATE()) - 7) + DATEDIFF(day, DATE_TRUNC('week', CURRENT_DATE()), CURRENT_DATE())
    FROM current_bp WHERE '{{ Granularity.value }}' = 'Week'
),
deal_owner_status AS (
    SELECT FULL_NAME, TEAM_NAME, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT
        s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IS NULL THEN 'Not Set'
            ELSE NULL
        END AS segment_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    WHERE s.IS_NEW_INTEGRATED = TRUE AND s.ROLLOUT_DATE IS NOT NULL
)
SELECT
    p.period,
    b.HUBSPOT_DEAL_OWNER              AS rep,
    u.TEAM_NAME                        AS team,
    SUM(b.PROPERTY_UNIT_COUNT)         AS units,
    COUNT(DISTINCT b.PROPERTY_ID)       AS properties
FROM bp_periods p
JOIN base b ON b.ROLLOUT_DATE BETWEEN p.start_date AND p.end_date
LEFT JOIN pmc_size pm ON b.PMC_ID = pm.PMC_ID
LEFT JOIN deal_owner_status u ON u.FULL_NAME = b.HUBSPOT_DEAL_OWNER
WHERE (pm.pmc_current_units IS NULL OR pm.pmc_current_units > 750)
  AND b.segment_bucket = '{{ Segment.value }}'
  AND b.HUBSPOT_DEAL_OWNER IS NOT NULL
  AND (u.FULL_NAME IS NULL OR u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
GROUP BY 1, 2, 3
ORDER BY period, units DESC;
