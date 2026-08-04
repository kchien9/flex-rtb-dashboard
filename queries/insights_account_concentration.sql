-- Account Concentration Risk -- blind spot #2 Kevin asked for: `insights_driver_concentration.sql`
-- already flags when ONE REP is carrying a team's number; nothing checks whether growth is
-- broad-based across PMCs/accounts or a handful of whale customers. Same underlying question,
-- one grain up (account instead of rep), reusing that file's threshold/materiality pattern
-- where it still fits, adjusted for a very different real distribution.
--
-- WHY TOP-5 COMBINED, NOT TOP-1 -- checked live: no single PMC is close to
-- insights_driver_concentration.sql's 40% rep-concentration threshold (confirmed live, current
-- month's largest PMC is 9.6% of total -- of 413 PMCs contributing this month). Account
-- concentration risk in a real business with hundreds of customers is a FEW-ACCOUNTS question,
-- not a one-account question -- top-5 combined share is the meaningful cut here, not top-1.
--
-- TRENDED, PLUS A STREAK, NOT A FIXED THRESHOLD -- checked live: top-5 share bounces 14-31%
-- over the trailing 8 months with no smooth pattern (which 5 PMCs are in the top 5 also
-- changes month to month) -- a fixed "top-5 > X%" threshold would be a fairly arbitrary line
-- given how much this genuinely moves on its own. Surfaced as a trend (Part A) plus a rising-
-- concentration streak scanner (Part B, same gaps-and-islands technique as
-- insights_declining_streaks.sql) so a genuinely SUSTAINED move gets flagged, not normal
-- month-to-month noise in which 5 accounts happen to be biggest.
--
-- Same DSMB exclusion (pmc_size, current live PMC total > 750) as every other file in this
-- repo. Company-wide by default; segment cut in Part A/B-Segment for "is this a Strategic-
-- specific whale-account risk or company-wide."

-- Part A: top-5 PMC combined share of total new+recaptured units, trended, company-wide.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
pmc_units AS (
    SELECT s.BP_MONTH, s.PMC_ID, ANY_VALUE(s.PMC_NAME) AS pmc_name,
        SUM(IFF(s.IS_NEW_INTEGRATED OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING units > 0
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY BP_MONTH ORDER BY units DESC) AS rnk,
        SUM(units) OVER (PARTITION BY BP_MONTH) AS month_total
    FROM pmc_units
)
SELECT
    BP_MONTH,
    SUM(units) AS top5_units,
    MAX(month_total) AS month_total,
    DIV0(SUM(units), MAX(month_total)) AS top5_share,
    ARRAY_AGG(pmc_name) WITHIN GROUP (ORDER BY units DESC) AS top5_pmcs
FROM ranked
WHERE rnk <= 5
GROUP BY 1
ORDER BY 1;

-- Part B: rising top-5-concentration streak, company-wide -- same technique as
-- insights_declining_streaks.sql, applied to top5_share instead of raw units.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
pmc_units AS (
    SELECT s.BP_MONTH, s.PMC_ID,
        SUM(IFF(s.IS_NEW_INTEGRATED OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0)) AS units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -12, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING units > 0
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY BP_MONTH ORDER BY units DESC) AS rnk,
        SUM(units) OVER (PARTITION BY BP_MONTH) AS month_total
    FROM pmc_units
),
monthly AS (
    SELECT BP_MONTH, DIV0(SUM(units), MAX(month_total)) AS top5_share
    FROM ranked WHERE rnk <= 5
    GROUP BY 1
),
with_change AS (
    SELECT *, SIGN(top5_share - LAG(top5_share) OVER (ORDER BY BP_MONTH)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (ORDER BY BP_MONTH) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (ORDER BY BP_MONTH) AS grp
    FROM with_lag
),
streaks AS (
    SELECT chg_sign, COUNT(*) AS streak_len, MAX(BP_MONTH) AS latest_month, MAX_BY(top5_share, BP_MONTH) AS latest_top5_share
    FROM with_group
    GROUP BY grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER ()
)
SELECT chg_sign AS direction, streak_len AS streak_months, latest_month, ROUND(latest_top5_share, 4) AS latest_top5_share
FROM streaks
WHERE chg_sign = 1 AND streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;
