-- Units Closed -> Rollout Forecast Bridge
-- Kevin's framing: closed units aren't just a separate metric from Rolled-Out Units --
-- they're the leading indicator FOR it. A deal closes, then (after implementation) its
-- properties roll out and become Rolled-Out Units. This query makes that lag visible
-- instead of leaving "closed" and "rolled out" as two disconnected numbers.
--
-- Bridge table: FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM -- new in the replatform, didn't
-- exist on the old tables. One row per property within a deal, with its own ROLLOUT_MONTH --
-- this is exactly the deal<->property bridge that used to require a HUBSPOT_DEAL_ID join
-- through PROPERTY_BP_MONTH_STATS. Use this table for anything connecting the two grains.
--
-- Validated against live Snowflake 2026-07-27, last 6 months of closed-won deals:
--   Units awaiting rollout (ROLLOUT_MONTH in the future): 36,412 line items
--   Units already rolled out (ROLLOUT_MONTH in the past): 276,678 line items
--   Median lag from CLOSED_AT_UTC to ROLLOUT_MONTH: 12 days (avg 13.4) -- fast, most deals
--   roll out within about 2 weeks of closing, not months.
--   By team, units still awaiting rollout right now: Strategic Team 99,151; Brandon's Team
--   44,758; SMB AEs 1/2 ~32k/23k -- this is literally "what's about to show up in Rolled-Out
--   Units in the next couple weeks," a real near-term forecast, not a guess.
--
-- TODO: apply the same DSMB account-size exclusion used elsewhere in this repo (PMC current
-- units <=750) -- not yet done here. Needs a join from PROPERTY_ID -> DIM_PROPERTY -> PMC_ID
-- -> the pmc_size CTE pattern in rolled_out_units_cube.sql. Flagging rather than guessing at
-- the join path without testing it live first.
--
-- FILTER ESCAPING -- same apostrophe risk as every other value filter in this repo.

SELECT
    COALESCE(e.TEAM_NAME, 'Not Set')                                          AS team,
    SUM(IFF(li.ROLLOUT_MONTH > CURRENT_DATE(), li.UNIT_COUNT, 0))             AS units_awaiting_rollout,
    COUNT(DISTINCT IFF(li.ROLLOUT_MONTH > CURRENT_DATE(), li.OPPORTUNITY_ID, NULL)) AS deals_awaiting_rollout,
    SUM(IFF(li.ROLLOUT_MONTH <= CURRENT_DATE(), li.UNIT_COUNT, 0))            AS units_already_rolled_out
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM li
JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON li.OPPORTUNITY_ID = o.OPPORTUNITY_ID
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
WHERE o.IS_CLOSED_WON
  AND o.CLOSED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, CURRENT_DATE())
  {{#Team.value}} AND e.TEAM_NAME = '{{Team.value}}' {{/Team.value}}
GROUP BY 1
ORDER BY 2 DESC;
