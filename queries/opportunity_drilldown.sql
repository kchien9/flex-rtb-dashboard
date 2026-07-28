-- Opportunity Drill-Down -- the bottom of every drill chain. Per Kevin: "i want the units to
-- have opportunity drill downs too. so when you drill into a rep i want to see the deals that
-- drive everything." Rolled-Out Units lives at PROPERTY grain (PROPERTY_BP_MONTH_STATS), which
-- is right for the top-level cube but not what a sales leader wants to see when they click all
-- the way down to a rep -- they want the actual DEALS, not a list of individual properties.
--
-- One query, filterable by every dimension already used elsewhere in this repo (Rep / Team /
-- BP month / Deal Type) so it can sit underneath ANY slice in rolled_out_units_cube.sql or
-- the rep leaderboard -- click a rep's bar, click a team's row, click a BP-month cell, all land
-- here with the corresponding filter set.
--
-- GRAIN: aggregated to OPPORTUNITY, not property line-item. FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM
-- is the bridge table used in units_closed_forecast_bridge.sql (deal-grain -> property-grain,
-- carries its own ROLLOUT_MONTH per property). A single opportunity can cover many properties
-- rolling out together (validated live: one Cory Baach expansion deal spanned 89 properties in
-- one BP month) -- summing to opportunity grain before display is what makes this a "here are
-- the deals" list instead of a 1000-row property list. Validated live 2026-07-27: Cory Baach's
-- opportunity-level rollup for last BP month sums to the same total (33,718 units) as his row
-- in rep_leaderboard.sql for the same period -- confirms the two views tie out.
--
-- FILTER ESCAPING -- same apostrophe risk as every value filter in this repo (see
-- rolled_out_units_cube.sql header). Team/Rep filters especially -- double apostrophes if
-- passing raw Mustache.

SELECT
    o.OPPORTUNITY_NAME                                 AS opportunity,
    o.OPPORTUNITY_TYPE                                 AS deal_type,
    e.FULL_NAME                                        AS rep,
    e.TEAM_NAME                                        AS team,
    li.ROLLOUT_MONTH                                   AS bp_month,
    SUM(li.UNIT_COUNT)                                 AS units,
    COUNT(DISTINCT li.PROPERTY_ID)                     AS properties,
    o.CLOSED_AT_UTC                                    AS closed_date,
    o.OPPORTUNITY_ID                                   AS opportunity_id
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM li
JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON li.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
LEFT JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON li.OPPORTUNITY_ID = o.OPPORTUNITY_ID
WHERE li.ROLLOUT_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
  {{#Rep.value}}       AND e.FULL_NAME = '{{Rep.value}}'         {{/Rep.value}}
  {{#Team.value}}      AND e.TEAM_NAME = '{{Team.value}}'        {{/Team.value}}
  {{#BpMonth.value}}   AND li.ROLLOUT_MONTH = '{{BpMonth.value}}' {{/BpMonth.value}}
  {{#DealType.value}}  AND o.OPPORTUNITY_TYPE = '{{DealType.value}}' {{/DealType.value}}
GROUP BY 1, 2, 3, 4, 5, 8, 9
ORDER BY units DESC;
