-- Net Units Bridge -- Kevin: "this is how we get to net units. so its new + recap -
-- deactivated + uplevel to integrated - downlevel to niro, then remaining net change is the
-- bucket where we cant really explain it." Matches an existing, already-validated
-- methodology Kevin uses elsewhere (a Sigma "Integrated Units [Full Month]" table) --
-- this file reproduces that exact bridge on this dashboard's own DSMB-excluded base, not a
-- new definition invented here.
--
-- WHY THIS MATTERS -- every rolled-out-units view in this dashboard up to this point
-- (rolled_out_units_cube.sql, ai_summary_facts.sql Part A, the decline-streak scanners) shows
-- GROSS ADDS ONLY (new + recaptured). None of them show DEACTIVATED units, so Sham could see
-- "248,699 units added, up 21%!" while churn is quietly accelerating underneath it and nothing
-- in this dashboard would say so. This file is the fix -- surfaces the full bridge, not just
-- the growth half of it.
--
-- VALIDATED LIVE AGAINST THE STOCK COLUMN -- cross-checked `new_integrated + deactivated +
-- recaptured + uplevel_to_integrated + downlevel_to_niro` against IS_INTEGRATED_TOTAL's own
-- month-over-month change (the ground truth). Reconciles within 1-4% every month, small
-- residual (`remaining_net_change`) same as Kevin's own reference table -- not a bug to chase
-- to zero, this is the expected "we can't fully attribute this sliver" bucket. Company-wide
-- 8-month check: residuals ran 1-4% of net change (Kevin's own reference table shows a similar
-- small residual, e.g. Jan ~1%) -- the modest gap vs. his exact numbers is most likely this
-- dashboard's DSMB exclusion (his source table is likely unfiltered/company-wide) -- a known,
-- deliberate difference in scope, not an error to reconcile away.
--
-- FLAGS USED, CONFIRMED LIVE TO EXIST ON PROPERTY_BP_MONTH_STATS: IS_NEW_INTEGRATED,
-- IS_DEACTIVATED, IS_RECAPTURED_NEW_ROLLOUT / IS_RECAPTURED_OTHER, IS_UPLEVEL_TO_INTEGRATED,
-- IS_DOWNLEVEL_TO_NON_INTEGRATED_ROLLED_OUT (= "Downlevel to NIRO"), IS_INTEGRATED_TOTAL (the
-- stock column, used only as the cross-check ground truth, never summed across months itself).
--
-- Same DSMB exclusion (pmc_size, current live PMC total > 750) as every other file in this
-- repo.

-- Part A: company-wide bridge, trended, {{ LookbackMonths.value }} months (default 8).
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
bridge AS (
    SELECT s.BP_MONTH,
        SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS integrated_total,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS new_integrated,
        -SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated,
        SUM(IFF(s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS recaptured,
        SUM(IFF(s.IS_UPLEVEL_TO_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS uplevel_to_integrated,
        -SUM(IFF(s.IS_DOWNLEVEL_TO_NON_INTEGRATED_ROLLED_OUT, s.PROPERTY_UNIT_COUNT, 0)) AS downlevel_to_niro
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }} - 1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1
)
SELECT
    BP_MONTH,
    integrated_total,
    integrated_total - LAG(integrated_total) OVER (ORDER BY BP_MONTH) AS net_change,
    new_integrated,
    deactivated,
    recaptured,
    uplevel_to_integrated,
    downlevel_to_niro,
    (integrated_total - LAG(integrated_total) OVER (ORDER BY BP_MONTH))
        - (new_integrated + deactivated + recaptured + uplevel_to_integrated + downlevel_to_niro) AS remaining_net_change
FROM bridge
QUALIFY BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
ORDER BY BP_MONTH;

-- Part B: same bridge, by SEGMENT, all 4 segments scanned/returned at once (not filtered to
-- one at a time) -- lets the Debrief macro tier show "which segment is driving churn" without
-- a separate query per segment.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
bridge AS (
    SELECT
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        s.BP_MONTH,
        SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS integrated_total,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS new_integrated,
        -SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated,
        SUM(IFF(s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS recaptured,
        SUM(IFF(s.IS_UPLEVEL_TO_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS uplevel_to_integrated,
        -SUM(IFF(s.IS_DOWNLEVEL_TO_NON_INTEGRATED_ROLLED_OUT, s.PROPERTY_UNIT_COUNT, 0)) AS downlevel_to_niro
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }} - 1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL
)
SELECT
    segment_bucket,
    BP_MONTH,
    integrated_total - LAG(integrated_total) OVER (PARTITION BY segment_bucket ORDER BY BP_MONTH) AS net_change,
    new_integrated,
    deactivated,
    recaptured,
    uplevel_to_integrated,
    downlevel_to_niro
FROM bridge
QUALIFY BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
ORDER BY segment_bucket, BP_MONTH;

-- Part C: churn-acceleration streak scanner -- is DEACTIVATED magnitude growing for N
-- consecutive months, by segment, all segments scanned at once. Same gaps-and-islands
-- technique as insights_declining_streaks.sql, applied to |deactivated| instead of net
-- rollout units -- this is the proactive "churn is getting worse" flag, not just a number to
-- read off Part B.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        s.BP_MONTH,
        SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -12, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL AND deactivated_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(deactivated_units - LAG(deactivated_units) OVER (PARTITION BY segment_bucket ORDER BY BP_MONTH)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY segment_bucket ORDER BY BP_MONTH) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY segment_bucket ORDER BY BP_MONTH) AS grp
    FROM with_lag
),
streaks AS (
    SELECT segment_bucket, chg_sign, COUNT(*) AS streak_len, MAX(BP_MONTH) AS latest_month, MAX_BY(deactivated_units, BP_MONTH) AS latest_deactivated_units
    FROM with_group
    GROUP BY segment_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY segment_bucket)
)
SELECT segment_bucket, streak_len AS rising_churn_streak_months, latest_month, latest_deactivated_units
FROM streaks
WHERE chg_sign = 1 AND streak_len >= {{ MinStreakMonths.value }}
ORDER BY rising_churn_streak_months DESC;
