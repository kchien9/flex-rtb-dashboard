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
-- BUG FOUND AND FIXED 2026-07-27 -- Kevin caught this live: the first version of this query
-- joined `li.PROPERTY_ID` (new table, internal numeric ID e.g. 1553602) to
-- `p.PROPERTY_PUBLIC_ID` (old table, "bv2..." string format) -- those never match, so the
-- join silently failed on EVERY row, making IS_ROLLED_OUT NULL regardless of actual status.
-- The query wasn't detecting stalled deals at all -- it was listing every closed deal older
-- than the threshold, whether it had rolled out or not. Real example of the false positive:
-- "Tricon Residential" showed as the #1 flagged deal (54,019 units, 151 days) despite having
-- actually rolled out in March -- `li.ROLLOUT_MONTH` said so directly, the broken join just
-- never surfaced it. Fixed by joining `li.PROPERTY_ID = p.PROPERTY_ID` (both numeric,
-- confirmed matching format via FLEX.MART.DIM_PROPERTY). Re-validated: Tricon correctly
-- resolves to IS_ROLLED_OUT = TRUE with the fix, and the real flagged list is now much
-- smaller and different (real top row: "Preferred Apartment Communities, Inc. Expansion",
-- Strategic Team, 5,351 units, 154 days).
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
    ON li.PROPERTY_ID = p.PROPERTY_ID
    AND p.BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
WHERE o.IS_CLOSED_WON
  AND o.CLOSED_AT_UTC <= DATEADD(day, -{{ RiskDaysThreshold.value }}, CURRENT_DATE())  -- default 24
  AND o.CLOSED_AT_UTC >= DATEADD(month, -6, CURRENT_DATE())
  AND (p.IS_ROLLED_OUT IS NULL OR p.IS_ROLLED_OUT = FALSE)
  {{#Team.value}} AND e.TEAM_NAME = '{{Team.value}}' {{/Team.value}}
GROUP BY 1, 2, 4, 5
HAVING SUM(li.UNIT_COUNT) >= {{ SizeFloor.value }}  -- default 100
ORDER BY units DESC;
