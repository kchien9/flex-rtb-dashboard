-- Watch List, Section 1: Large Deals at Risk
-- Sham's grain, not a rep's -- deal-level, size-weighted. A small stalled deal isn't worth
-- his attention (that's the AE manager's problem); a big one closed months ago and still not
-- rolled out is exactly the kind of thing he should see without having to go looking for it.
--
-- Threshold: flags deals closed more than 24 days ago (2x the validated median close->rollout
-- lag of 12 days, see units_closed_forecast_bridge.sql) that still show no rollout, sized
-- >= 100 units. Both numbers are starting guesses -- tune SIZE_FLOOR and the day threshold
-- against what Sham actually finds worth seeing vs. noise.
--
-- Validated against live Snowflake 2026-07-27 -- real example, not illustrative:
--   "Tricon Residential - Larger Opp after pilot" (Strategic Team) -- 54,019 units, closed
--   151 days ago, still not rolled out. That's the #1 row today.
--
-- JOIN CAVEAT: li.PROPERTY_ID (new table) joined to p.PROPERTY_PUBLIC_ID (old table) --
-- this returned real, plausible rows in testing, but the join hasn't been independently
-- verified against a known-good property list. Spot-check a few rows against Salesforce
-- before fully trusting this at scale.
--
-- FILTER ESCAPING -- same apostrophe risk as every value filter in this repo.

SELECT
    o.OPPORTUNITY_NAME                                     AS deal,
    COALESCE(e.TEAM_NAME, 'Not Set')                        AS team,
    SUM(li.UNIT_COUNT)                                      AS units,
    o.CLOSED_AT_UTC                                         AS closed_date,
    DATEDIFF(day, o.CLOSED_AT_UTC, CURRENT_DATE())          AS days_since_close,
    o.OPPORTUNITY_NAME || ' (' || SUM(li.UNIT_COUNT) || ' units) closed ' ||
        DATEDIFF(day, o.CLOSED_AT_UTC, CURRENT_DATE()) ||
        ' days ago and still hasn''t rolled out'            AS callout
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM li
JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON li.OPPORTUNITY_ID = o.OPPORTUNITY_ID
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
LEFT JOIN PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS p
    ON li.PROPERTY_ID = p.PROPERTY_PUBLIC_ID
    AND p.BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
WHERE o.IS_CLOSED_WON
  AND o.CLOSED_AT_UTC <= DATEADD(day, -{{ RiskDaysThreshold.value }}, CURRENT_DATE())  -- default 24
  AND o.CLOSED_AT_UTC >= DATEADD(month, -6, CURRENT_DATE())
  AND (p.IS_ROLLED_OUT IS NULL OR p.IS_ROLLED_OUT = FALSE)
  {{#Team.value}} AND e.TEAM_NAME = '{{Team.value}}' {{/Team.value}}
GROUP BY 1, 2, 4, 5
HAVING SUM(li.UNIT_COUNT) >= {{ SizeFloor.value }}  -- default 100
ORDER BY units DESC;
