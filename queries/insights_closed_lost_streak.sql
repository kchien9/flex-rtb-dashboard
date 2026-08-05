-- Closed-Lost Rate Streak Scanner -- fulfills the Stage 2 item flagged as deferred earlier
-- this session ("generalize insights_closed_lost_trend.sql into a multi-entity scanner").
-- Kevin: "so sham can be like huh we're losing a lot of x msp deals - why?" Same partitioned
-- gaps-and-islands streak technique as the other 9 scanners in this dashboard, applied to
-- loss_rate_by_units across segment (Part A), team (Part B), MSP (Part C), and deal type
-- (Part D) -- scans every slice of each dimension at once, not just whichever filter is
-- currently selected.
--
-- DIRECTION MATTERS HERE -- a RISING loss rate is the one flag worth surfacing (chg_sign = 1),
-- same "direction matters" convention as insights_net_units_bridge.sql's churn-rising streak
-- and insights_niro_mix_trend.sql's NIRO-share-rising streak. A falling loss rate is good news,
-- not a comparably-weighted flag.
--
-- MATERIALITY FLOOR ON DEAL COUNT, NOT UNITS -- a rate metric's noise driver is few DEALS (a
-- 2-deal MSP-month swings 0%->50%->100% on a single closing), not raw unit volume -- same
-- reasoning closed_lost_analysis.sql's own header already established for why deal count must
-- sit next to the unit-weighted rate. `{{ MinDealsFloor.value }}` applied per period per slice.
--
-- REP EXCLUDED FROM THIS SCANNER -- same reasoning as closed_lost_analysis.sql Part C: a
-- single BP month's closed-deal count per rep is often single digits, the exact small-sample
-- noise a streak scanner would amplify, not detect. Rep-level loss rate stays a one-window
-- total (Part C of that file), not a monthly streak.
--
-- Calendar month, not BP month (deal closing is a Salesforce-native event, matching
-- closed_lost_rate_cube.sql/closed_lost_analysis.sql's existing convention). Same DSMB
-- exclusion (Pattern B via DIM_CRM_ACCOUNT_HISTORY.PMC_ID). Month/Quarter
-- {{ Granularity.value }} toggle built in from the start.
--
-- FULLY-ELAPSED MONTHS ONLY, PURE CALENDAR CHECK -- BUG CAUGHT LIVE 2026-08-04: the first
-- draft's completeness gate compared the calendar month of CLOSED_AT_UTC against a BP-month
-- LABEL (same construction closed_lost_analysis.sql Part B already uses) -- that mixes two
-- different calendars. Confirmed live on 2026-08-05: DAY(CURRENT_DATE()) > 4 already flips the
-- BP label to Sep BP (2026-09-01), so "calendar month < 2026-09-01" let August 2026 -- 5 of 31
-- days in -- through as "complete." Every dimension immediately flagged a simultaneous,
-- dramatic "1-period rising streak" at 72-98% loss rates, concentrated entirely in that one
-- barely-started month -- the exact tiny-sample-looks-like-a-collapse artifact this repo's own
-- censoring logic exists to prevent. Fixed to a pure calendar check with no BP-label mixing:
-- `DATE_TRUNC('month', CLOSED_AT_UTC) < DATE_TRUNC('month', CURRENT_DATE())`. Same bug fixed in
-- `closed_lost_rate_cube.sql` and flagged as pre-existing in `closed_lost_analysis.sql` Part B.

-- Part A: segment-level loss-rate rising streak.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT o.*,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            ELSE NULL
        END AS segment_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND DATE_TRUNC('month', o.CLOSED_AT_UTC) < DATE_TRUNC('month', CURRENT_DATE())
      AND o.CLOSED_AT_UTC >= DATEADD(month, -24, DATE_TRUNC('month', CURRENT_DATE()))
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
),
monthly AS (
    SELECT
        segment_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', DATE_TRUNC('month', CLOSED_AT_UTC)), DATE_TRUNC('month', CLOSED_AT_UTC)) AS period,
        COUNT(*) AS total_deals,
        DIV0(SUM(IFF(NOT IS_CLOSED_WON, FLEX_UNIT_COUNT, 0)), SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0))) AS loss_rate_by_units
    FROM scoped
    WHERE segment_bucket IS NOT NULL
    GROUP BY 1, 2
    HAVING total_deals >= {{ MinDealsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(loss_rate_by_units - LAG(loss_rate_by_units) OVER (PARTITION BY segment_bucket ORDER BY period)) AS chg_sign
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
    SELECT segment_bucket, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_period, MAX_BY(loss_rate_by_units, period) AS latest_loss_rate
    FROM with_group
    GROUP BY segment_bucket, grp, chg_sign
    QUALIFY latest_period = MAX(latest_period) OVER (PARTITION BY segment_bucket)
)
SELECT segment_bucket, streak_len AS streak_periods, latest_period, ROUND(latest_loss_rate, 4) AS latest_loss_rate_by_units
FROM streaks
WHERE chg_sign = 1 AND streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_periods DESC;

-- Part B: team-level loss-rate rising streak. Same technique, PARTITION BY team_bucket.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT o.*,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND DATE_TRUNC('month', o.CLOSED_AT_UTC) < DATE_TRUNC('month', CURRENT_DATE())
      AND o.CLOSED_AT_UTC >= DATEADD(month, -24, DATE_TRUNC('month', CURRENT_DATE()))
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
),
monthly AS (
    SELECT
        team_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', DATE_TRUNC('month', CLOSED_AT_UTC)), DATE_TRUNC('month', CLOSED_AT_UTC)) AS period,
        COUNT(*) AS total_deals,
        DIV0(SUM(IFF(NOT IS_CLOSED_WON, FLEX_UNIT_COUNT, 0)), SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0))) AS loss_rate_by_units
    FROM scoped
    WHERE team_bucket IS NOT NULL
    GROUP BY 1, 2
    HAVING total_deals >= {{ MinDealsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(loss_rate_by_units - LAG(loss_rate_by_units) OVER (PARTITION BY team_bucket ORDER BY period)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY team_bucket ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY team_bucket ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT team_bucket, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_period, MAX_BY(loss_rate_by_units, period) AS latest_loss_rate
    FROM with_group
    GROUP BY team_bucket, grp, chg_sign
    QUALIFY latest_period = MAX(latest_period) OVER (PARTITION BY team_bucket)
)
SELECT team_bucket, streak_len AS streak_periods, latest_period, ROUND(latest_loss_rate, 4) AS latest_loss_rate_by_units
FROM streaks
WHERE chg_sign = 1 AND streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_periods DESC;

-- Part C: MSP-level loss-rate rising streak. Same technique, PARTITION BY msp
-- (PARTNER_MANAGEMENT_SOFTWARE, deal-grain -- same field insights_declining_streaks.sql Part B
-- already validated).
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT o.*,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            ELSE NULL
        END AS segment_bucket,
        COALESCE(o.PARTNER_MANAGEMENT_SOFTWARE, 'Not Set') AS msp
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND DATE_TRUNC('month', o.CLOSED_AT_UTC) < DATE_TRUNC('month', CURRENT_DATE())
      AND o.CLOSED_AT_UTC >= DATEADD(month, -24, DATE_TRUNC('month', CURRENT_DATE()))
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      AND segment_bucket IS NOT NULL
)
, monthly AS (
    SELECT
        msp,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', DATE_TRUNC('month', CLOSED_AT_UTC)), DATE_TRUNC('month', CLOSED_AT_UTC)) AS period,
        COUNT(*) AS total_deals,
        DIV0(SUM(IFF(NOT IS_CLOSED_WON, FLEX_UNIT_COUNT, 0)), SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0))) AS loss_rate_by_units
    FROM scoped
    GROUP BY 1, 2
    HAVING total_deals >= {{ MinDealsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(loss_rate_by_units - LAG(loss_rate_by_units) OVER (PARTITION BY msp ORDER BY period)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY msp ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY msp ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT msp, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_period, MAX_BY(loss_rate_by_units, period) AS latest_loss_rate
    FROM with_group
    GROUP BY msp, grp, chg_sign
    QUALIFY latest_period = MAX(latest_period) OVER (PARTITION BY msp)
)
SELECT msp, streak_len AS streak_periods, latest_period, ROUND(latest_loss_rate, 4) AS latest_loss_rate_by_units
FROM streaks
WHERE chg_sign = 1 AND streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_periods DESC;

-- Part D: deal-type-level loss-rate rising streak. Same technique, PARTITION BY deal_type.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT o.*,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            ELSE NULL
        END AS segment_bucket,
        o.OPPORTUNITY_TYPE AS deal_type
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND DATE_TRUNC('month', o.CLOSED_AT_UTC) < DATE_TRUNC('month', CURRENT_DATE())
      AND o.CLOSED_AT_UTC >= DATEADD(month, -24, DATE_TRUNC('month', CURRENT_DATE()))
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      AND segment_bucket IS NOT NULL
)
, monthly AS (
    SELECT
        deal_type,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', DATE_TRUNC('month', CLOSED_AT_UTC)), DATE_TRUNC('month', CLOSED_AT_UTC)) AS period,
        COUNT(*) AS total_deals,
        DIV0(SUM(IFF(NOT IS_CLOSED_WON, FLEX_UNIT_COUNT, 0)), SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0))) AS loss_rate_by_units
    FROM scoped
    GROUP BY 1, 2
    HAVING total_deals >= {{ MinDealsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(loss_rate_by_units - LAG(loss_rate_by_units) OVER (PARTITION BY deal_type ORDER BY period)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY deal_type ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY deal_type ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT deal_type, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_period, MAX_BY(loss_rate_by_units, period) AS latest_loss_rate
    FROM with_group
    GROUP BY deal_type, grp, chg_sign
    QUALIFY latest_period = MAX(latest_period) OVER (PARTITION BY deal_type)
)
SELECT deal_type, streak_len AS streak_periods, latest_period, ROUND(latest_loss_rate, 4) AS latest_loss_rate_by_units
FROM streaks
WHERE chg_sign = 1 AND streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_periods DESC;
