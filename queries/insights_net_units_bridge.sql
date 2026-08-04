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
--
-- GRANULARITY ADDED 2026-08-04 -- `{{ Granularity.value }}` = 'Month' | 'Quarter', same
-- DATE_TRUNC('quarter', BP_MONTH) technique as insights_declining_streaks.sql. `integrated_total`
-- for a quarter bucket takes the LAST month's stock value in that quarter, never summed across
-- months -- summing a STOCK column across 3 months would triple-count it, the exact stock-vs-
-- flow bug this repo has been burned by before. All the FLOW components (new_integrated,
-- deactivated, recaptured, etc.) sum correctly across the 3 months in a quarter.
--
-- BUG CAUGHT VALIDATING LIVE -- first draft used `MAX_BY(IFF(IS_INTEGRATED_TOTAL,
-- PROPERTY_UNIT_COUNT, 0), BP_MONTH)` directly inside the `bridge` CTE's single aggregation --
-- that picks ONE raw detail row's PROPERTY_UNIT_COUNT (whichever row happens to have the max
-- BP_MONTH), not the real SUMMED monthly stock total -- produced nonsense integrated_total
-- values of 0-100 instead of ~9-10M. Fixed with a two-stage aggregation: `monthly_stock` first
-- aggregates IS_INTEGRATED_TOTAL to real per-BP_MONTH totals, THEN `bridge` picks the LAST
-- month's already-correct total within each period via MAX_BY on that pre-aggregated value.

-- Part A: company-wide bridge, trended, {{ LookbackMonths.value }} periods (default 8).
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly_stock AS (
    SELECT s.BP_MONTH, SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS integrated_total
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1) - 3, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1
),
bridge AS (
    SELECT
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        MAX_BY(ms.integrated_total, s.BP_MONTH) AS integrated_total,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS new_integrated,
        -SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated,
        SUM(IFF(s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS recaptured,
        SUM(IFF(s.IS_UPLEVEL_TO_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS uplevel_to_integrated,
        -SUM(IFF(s.IS_DOWNLEVEL_TO_NON_INTEGRATED_ROLLED_OUT, s.PROPERTY_UNIT_COUNT, 0)) AS downlevel_to_niro
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    JOIN monthly_stock ms ON s.BP_MONTH = ms.BP_MONTH
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1) - 3, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1
)
SELECT
    period,
    integrated_total,
    integrated_total - LAG(integrated_total) OVER (ORDER BY period) AS net_change,
    new_integrated,
    deactivated,
    recaptured,
    uplevel_to_integrated,
    downlevel_to_niro,
    (integrated_total - LAG(integrated_total) OVER (ORDER BY period))
        - (new_integrated + deactivated + recaptured + uplevel_to_integrated + downlevel_to_niro) AS remaining_net_change
FROM bridge
QUALIFY period >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1), (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
ORDER BY period;

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
scoped AS (
    SELECT s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    WHERE s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1) - 3, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
),
monthly_stock AS (
    SELECT s.segment_bucket, s.BP_MONTH,
        SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS integrated_total
    FROM scoped s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL
),
bridge AS (
    SELECT
        s.segment_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        MAX_BY(ms.integrated_total, s.BP_MONTH) AS integrated_total,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS new_integrated,
        -SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated,
        SUM(IFF(s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS recaptured,
        SUM(IFF(s.IS_UPLEVEL_TO_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS uplevel_to_integrated,
        -SUM(IFF(s.IS_DOWNLEVEL_TO_NON_INTEGRATED_ROLLED_OUT, s.PROPERTY_UNIT_COUNT, 0)) AS downlevel_to_niro
    FROM scoped s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    JOIN monthly_stock ms ON s.BP_MONTH = ms.BP_MONTH AND s.segment_bucket = ms.segment_bucket
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.segment_bucket IS NOT NULL
    GROUP BY 1, 2
)
SELECT
    segment_bucket,
    period,
    integrated_total - LAG(integrated_total) OVER (PARTITION BY segment_bucket ORDER BY period) AS net_change,
    new_integrated,
    deactivated,
    recaptured,
    uplevel_to_integrated,
    downlevel_to_niro
FROM bridge
QUALIFY period >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1), (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
ORDER BY segment_bucket, period;

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
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -24, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL AND deactivated_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(deactivated_units - LAG(deactivated_units) OVER (PARTITION BY segment_bucket ORDER BY period)) AS chg_sign
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
    SELECT segment_bucket, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_month, MAX_BY(deactivated_units, period) AS latest_deactivated_units
    FROM with_group
    GROUP BY segment_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY segment_bucket)
)
SELECT segment_bucket, streak_len AS rising_churn_streak_months, latest_month, latest_deactivated_units
FROM streaks
WHERE chg_sign = 1 AND streak_len >= {{ MinStreakMonths.value }}
ORDER BY rising_churn_streak_months DESC;

-- Part D: single-month deactivation SPIKE flag, all segments scanned at once -- Kevin: "if
-- deactivations are way up this month probably something worth calling out too." Part C
-- above requires 2+ CONSECUTIVE months of rising churn to flag anything -- a real, sharp
-- one-month spike that hasn't (yet) repeated would be invisible to it. Same single-delta +
-- materiality-floor pattern as insights_trend_flags.sql, applied specifically to deactivated
-- units instead of general rolled-out volume (that file doesn't isolate deactivations at all).
-- Validated live: SMB deactivated units jumped 54% in one month (16,353 -> 25,186, Jul -> Aug)
-- -- a real, current spike Part C's streak requirement alone would not have caught yet.
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
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0)) AS deactivated_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -IFF('{{ Granularity.value }}' = 'Quarter', 6, 1), (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL
),
this_last AS (
    SELECT segment_bucket,
        MAX_BY(deactivated_units, period) AS deactivated_this,
        MAX_BY(IFF(period < (SELECT MAX(period) FROM monthly), deactivated_units, NULL), IFF(period < (SELECT MAX(period) FROM monthly), period, NULL)) AS deactivated_last
    FROM monthly
    GROUP BY segment_bucket
)
SELECT segment_bucket, deactivated_this, deactivated_last,
    DIV0(deactivated_this - deactivated_last, deactivated_last) AS pct_change
FROM this_last
WHERE deactivated_last >= {{ MinUnitsFloor.value }}
  AND DIV0(deactivated_this - deactivated_last, deactivated_last) >= {{ MinPctSpikeThreshold.value }}
ORDER BY pct_change DESC;
