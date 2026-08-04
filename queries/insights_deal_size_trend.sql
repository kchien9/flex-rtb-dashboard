-- Average Deal Size Trend -- blind spot #5 Kevin asked for: the same total volume can come
-- from many small deals or a few big ones -- an efficiency/mix signal distinct from win rate,
-- cycle time, or total units. Nothing in this dashboard currently trends deal size itself.
--
-- MEDIAN IS THE PRIMARY METRIC, NOT AVERAGE -- checked live before building this: the
-- distribution is heavily right-skewed (MM/Ent Dec 2025: average 952 units/deal vs. median
-- 308 -- a handful of whale deals pull the average way up). Same reason this repo already
-- prefers MEDIAN elsewhere (sales_cycle_time_by_segment.sql) -- a single huge deal would swing
-- an average-based streak artificially. `avg_deal_size` still shown alongside for context
-- (a widening average-vs-median gap is itself informative -- means one or two deals are
-- unusually large that period), but the streak in Part B is on the median.
--
-- BOTH DIRECTIONS SURFACE -- shrinking average deal size isn't inherently bad (could mean
-- broader-based, more numerous wins) and growing isn't inherently good (could mean fewer,
-- riskier concentrated deals) -- same "mix signal, not decline-only" reasoning as
-- insights_mix_shift_scanner.sql and insights_cycle_time_trend.sql.
--
-- VALIDATED LIVE: real, multi-month declining pattern in both MM/Ent and SMB median deal size
-- over the trailing 8 months (MM/Ent 308 -> ~205-250 range, SMB 261 -> 30-77 range) -- a real
-- signal worth surfacing, not a hypothetical.
--
-- BP MONTH, NOT CALENDAR -- caught while validating: an earlier draft claimed the deals-count
-- floor would naturally exclude a partial current month, then bucketed by calendar month
-- anyway. That claim turned out FALSE live -- a partial calendar month can still clear a
-- reasonable deals floor (14 deals is a real sample, not obviously partial) while still being
-- an incomplete period. Fixed to bucket by BP month instead, matching this repo's standing
-- convention everywhere else -- median deal SIZE isn't mechanically biased by a partial period
-- the way a SUM/COUNT would be, but bucketing consistently avoids ever mislabeling a
-- still-forming BP month as complete in the narration layer.
--
-- GRANULARITY ADDED 2026-08-04 -- `{{ Granularity.value }}` = 'Month' | 'Quarter', same
-- DATE_TRUNC('quarter', bp_month) technique as the other scanners.

-- Part A: trended avg + median deal size, by segment.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
with_bp_month AS (
    SELECT
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            ELSE NULL
        END AS segment_bucket,
        IFF(DAY(o.CLOSED_AT_UTC) <= 4, DATE_TRUNC('month', o.CLOSED_AT_UTC), DATE_TRUNC('month', DATEADD(month, 1, o.CLOSED_AT_UTC))) AS bp_month,
        o.FLEX_UNIT_COUNT
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED_WON AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND o.FLEX_UNIT_COUNT IS NOT NULL
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      AND o.CLOSED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1) - 1, CURRENT_DATE())
),
monthly AS (
    SELECT
        segment_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', bp_month), bp_month) AS period,
        AVG(FLEX_UNIT_COUNT) AS avg_deal_size,
        MEDIAN(FLEX_UNIT_COUNT) AS median_deal_size,
        COUNT(*) AS deals
    FROM with_bp_month
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL AND deals >= {{ MinDealsFloor.value }}
)
SELECT segment_bucket, period, ROUND(avg_deal_size, 0) AS avg_deal_size, median_deal_size, deals
FROM monthly
ORDER BY segment_bucket, period;

-- Part B: median deal size streak, all segments scanned at once.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
with_bp_month AS (
    SELECT
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            ELSE NULL
        END AS segment_bucket,
        IFF(DAY(o.CLOSED_AT_UTC) <= 4, DATE_TRUNC('month', o.CLOSED_AT_UTC), DATE_TRUNC('month', DATEADD(month, 1, o.CLOSED_AT_UTC))) AS bp_month,
        o.FLEX_UNIT_COUNT
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED_WON AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND o.FLEX_UNIT_COUNT IS NOT NULL
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      AND o.CLOSED_AT_UTC >= DATEADD(month, -24, CURRENT_DATE())
),
monthly AS (
    SELECT
        segment_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', bp_month), bp_month) AS period,
        MEDIAN(FLEX_UNIT_COUNT) AS median_deal_size,
        COUNT(*) AS deals
    FROM with_bp_month
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL AND deals >= {{ MinDealsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(median_deal_size - LAG(median_deal_size) OVER (PARTITION BY segment_bucket ORDER BY period)) AS chg_sign
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
    SELECT segment_bucket, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_month, MAX_BY(median_deal_size, period) AS latest_median_deal_size
    FROM with_group
    GROUP BY segment_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY segment_bucket)
)
SELECT segment_bucket, chg_sign AS direction, streak_len AS streak_months, latest_month, latest_median_deal_size
FROM streaks
WHERE streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;
