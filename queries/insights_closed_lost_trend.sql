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

-- Part A: monthly loss-rate trend
SELECT
    DATE_TRUNC('month', CLOSED_AT_UTC)                                        AS month,
    COUNT(DISTINCT IFF(IS_CLOSED_WON, OPPORTUNITY_ID, NULL))                  AS closed_won_deals,
    COUNT(DISTINCT IFF(IS_CLOSED AND NOT IS_CLOSED_WON, OPPORTUNITY_ID, NULL)) AS closed_lost_deals,
    DIV0(COUNT(DISTINCT IFF(IS_CLOSED AND NOT IS_CLOSED_WON, OPPORTUNITY_ID, NULL)),
         COUNT(DISTINCT IFF(IS_CLOSED, OPPORTUNITY_ID, NULL)))                AS lost_rate,
    -- month-over-month change in lost_rate, in percentage points -- easier for Sham to read
    -- than a ratio of ratios ("lost rate is up 5pts" vs "lost rate rate is up 1.4x")
    DIV0(COUNT(DISTINCT IFF(IS_CLOSED AND NOT IS_CLOSED_WON, OPPORTUNITY_ID, NULL)),
         COUNT(DISTINCT IFF(IS_CLOSED, OPPORTUNITY_ID, NULL)))
    - LAG(DIV0(COUNT(DISTINCT IFF(IS_CLOSED AND NOT IS_CLOSED_WON, OPPORTUNITY_ID, NULL)),
               COUNT(DISTINCT IFF(IS_CLOSED, OPPORTUNITY_ID, NULL))))
      OVER (ORDER BY DATE_TRUNC('month', CLOSED_AT_UTC))                      AS lost_rate_ppt_change
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY
WHERE IS_CLOSED
  AND CLOSED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, CURRENT_DATE())
  {{#Team.value}} AND STATIC_TEAM_NAME = '{{Team.value}}' {{/Team.value}}
GROUP BY 1
-- drop the current in-progress month from the trend line -- it will always look artificially
-- low/volatile since most of the month's deals haven't closed one way or the other yet. Show
-- it separately in the UI as "in progress" if useful, don't let it distort the trend.
QUALIFY month < DATE_TRUNC('month', CURRENT_DATE())
ORDER BY 1;

-- Part B: reason breakdown for the most recent complete month -- the "what's driving it"
SELECT
    COALESCE(CLOSED_LOST_REASON, 'Not Set')                                   AS reason,
    COUNT(*)                                                                  AS deals,
    SUM(FLEX_UNIT_COUNT)                                                      AS units,
    DIV0(COUNT(*), SUM(COUNT(*)) OVER ())                                     AS pct_of_losses
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY
WHERE IS_CLOSED AND NOT IS_CLOSED_WON
  AND CLOSED_AT_UTC >= DATEADD(month, -1, DATE_TRUNC('month', CURRENT_DATE()))
  AND CLOSED_AT_UTC < DATE_TRUNC('month', CURRENT_DATE())
  {{#Team.value}} AND STATIC_TEAM_NAME = '{{Team.value}}' {{/Team.value}}
GROUP BY 1
ORDER BY deals DESC;
