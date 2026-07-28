-- Pipeline Forecast -- "based on pipeline (go live / close date) what are we expecting down
-- the road" (Kevin). Real, validated field: FLEX.SALES.FCT_CRM_OPPORTUNITY.
-- ANTICIPATED_GO_LIVE_AT_UTC sits directly on the OPEN opportunity, not just on closed deals
-- -- this extends the same forecasting idea in units_closed_forecast_bridge.sql (which
-- covers already-CLOSED deals awaiting rollout) one step further upstream, to still-OPEN
-- pipeline.
--
-- UNWEIGHTED ON PURPOSE -- this shows every open deal's units at 100% of face value grouped
-- by its anticipated go-live month, NOT probability-weighted by stage. A real stage-win-rate
-- weighting is a separate, already-identified future project (see
-- project_pipeline_win_rates.md -- "build real pipeline expected value using actual Flex win
-- rates by stage", explicitly deferred, not built yet because there's no validated win-rate-
-- by-stage table to weight against). Don't present this as "expected units," present it as
-- "pipeline units currently scheduled to go live" -- a real but optimistic ceiling, not a
-- probability-adjusted forecast. Mislabeling this as a weighted forecast would be a real
-- accuracy problem, not just a framing nitpick.
--
-- TEAM ATTRIBUTION -- validated live 2026-07-28: STATIC_TEAM_NAME (deal-grain) is almost
-- entirely NULL on OPEN opportunities (838 of 839 August-expected deals had no team tag at
-- all) -- that field apparently gets populated later in the deal lifecycle, not at creation.
-- Switched to OWNER_SK -> DIM_EMPLOYEE_HISTORY.TEAM_NAME (rep-grain, same team_bucket mapping
-- used everywhere else) instead -- meaningfully better coverage, though still real gaps
-- (~700 of the ~840 August-expected deals still show no current owner/team -- flagging, not
-- hiding, via the "Not Set" bucket below).

SELECT
    DATE_TRUNC('month', o.ANTICIPATED_GO_LIVE_AT_UTC)                          AS expected_month,
    COALESCE(
        CASE
            WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN e.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN e.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END, 'Not Set')                                                        AS team_bucket,
    o.OPPORTUNITY_TYPE                                                         AS deal_type,
    COUNT(*)                                                                   AS open_deals,
    SUM(o.FLEX_UNIT_COUNT)                                                     AS pipeline_units
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
WHERE NOT o.IS_CLOSED
  AND o.ANTICIPATED_GO_LIVE_AT_UTC >= CURRENT_DATE()
  AND o.ANTICIPATED_GO_LIVE_AT_UTC <= DATEADD(month, {{ LookaheadMonths.value }}, CURRENT_DATE())
  {{#Team.value}} AND COALESCE(
        CASE
            WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN e.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN e.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END, 'Not Set') = '{{Team.value}}' {{/Team.value}}
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;
