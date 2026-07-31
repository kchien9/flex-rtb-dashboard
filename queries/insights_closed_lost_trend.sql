-- Closed-Lost Trend -- is our loss rate going up, and what's driving it. Two parts: a
-- monthly loss-rate trend (are we losing a bigger share of what we close, over time) and a
-- reason breakdown for the most recent period (the "why"). Per Kevin: "are closed losts going
-- up % wise from a certain time over a certain time frame? whats driving it? what reason?"
--
-- Loss RATE, not raw count -- raw closed-lost count rises and falls with total deal volume,
-- which isn't the signal. Rate (lost / (won + lost)) isolates whether we're actually
-- converting worse, independent of how many deals are in flight.
--
-- CLOSED_LOST_REASON is a real, populated field on FLEX.SALES.FCT_CRM_OPPORTUNITY -- validated
-- live 2026-07-27, no join needed. Top reasons on real data (trailing 2 months): Auto Close -
-- Inactivity, Contact stopped responding, Other, Duplicate Opportunity, Not Interested --
-- mostly disengagement/hygiene reasons, not competitive losses. Worth flagging to Sham as-is:
-- if "Auto Close - Inactivity" is the top driver of a rate increase, that's a follow-up/hygiene
-- problem, not a pricing or product problem, and should be framed that way in the dashboard.
--
-- Uses CLOSED_AT_UTC (calendar month), not BP month -- deal closing is a Salesforce-native
-- event, not a rollout event, so there's no BP-alignment reason to use the BP calendar here.
--
-- DSMB EXCLUSION ADDED 2026-07-31 -- neither part had any account-size filter -- caught in a
-- repo-wide DSMB audit. This is a company-wide leadership trend metric, exactly where a
-- handful of DSMB deals (which skew toward disengagement/hygiene closes, per this file's own
-- finding above) could distort the rate. Same Pattern B pmc_size join as performance_cube.sql.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
)
-- Part A: monthly loss-rate trend
SELECT
    DATE_TRUNC('month', o.CLOSED_AT_UTC)                                        AS month,
    COUNT(DISTINCT IFF(o.IS_CLOSED_WON, o.OPPORTUNITY_ID, NULL))                  AS closed_won_deals,
    COUNT(DISTINCT IFF(o.IS_CLOSED AND NOT o.IS_CLOSED_WON, o.OPPORTUNITY_ID, NULL)) AS closed_lost_deals,
    DIV0(COUNT(DISTINCT IFF(o.IS_CLOSED AND NOT o.IS_CLOSED_WON, o.OPPORTUNITY_ID, NULL)),
         COUNT(DISTINCT IFF(o.IS_CLOSED, o.OPPORTUNITY_ID, NULL)))                AS lost_rate,
    -- month-over-month change in lost_rate, in percentage points -- easier for Sham to read
    -- than a ratio of ratios ("lost rate is up 5pts" vs "lost rate rate is up 1.4x")
    DIV0(COUNT(DISTINCT IFF(o.IS_CLOSED AND NOT o.IS_CLOSED_WON, o.OPPORTUNITY_ID, NULL)),
         COUNT(DISTINCT IFF(o.IS_CLOSED, o.OPPORTUNITY_ID, NULL)))
    - LAG(DIV0(COUNT(DISTINCT IFF(o.IS_CLOSED AND NOT o.IS_CLOSED_WON, o.OPPORTUNITY_ID, NULL)),
               COUNT(DISTINCT IFF(o.IS_CLOSED, o.OPPORTUNITY_ID, NULL))))
      OVER (ORDER BY DATE_TRUNC('month', o.CLOSED_AT_UTC))                      AS lost_rate_ppt_change
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
WHERE o.IS_CLOSED
  AND o.CLOSED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, CURRENT_DATE())
  AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
  {{#Team.value}} AND o.STATIC_TEAM_NAME = '{{Team.value}}' {{/Team.value}}
GROUP BY 1
-- drop the current in-progress month from the trend line -- it will always look artificially
-- low/volatile since most of the month's deals haven't closed one way or the other yet. Show
-- it separately in the UI as "in progress" if useful, don't let it distort the trend.
QUALIFY month < DATE_TRUNC('month', CURRENT_DATE())
ORDER BY 1;

-- Part B: reason breakdown for the most recent complete month -- the "what's driving it"
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
)
SELECT
    COALESCE(o.CLOSED_LOST_REASON, 'Not Set')                                   AS reason,
    COUNT(*)                                                                  AS deals,
    SUM(o.FLEX_UNIT_COUNT)                                                      AS units,
    DIV0(COUNT(*), SUM(COUNT(*)) OVER ())                                     AS pct_of_losses
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
WHERE o.IS_CLOSED AND NOT o.IS_CLOSED_WON
  AND o.CLOSED_AT_UTC >= DATEADD(month, -1, DATE_TRUNC('month', CURRENT_DATE()))
  AND o.CLOSED_AT_UTC < DATE_TRUNC('month', CURRENT_DATE())
  AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
  {{#Team.value}} AND o.STATIC_TEAM_NAME = '{{Team.value}}' {{/Team.value}}
GROUP BY 1
ORDER BY deals DESC;
