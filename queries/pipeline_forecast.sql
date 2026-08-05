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
--
-- DSMB EXCLUSION ADDED 2026-07-31 -- neither Part A nor Part B had ANY account-size filter --
-- caught in a repo-wide DSMB audit per Kevin's explicit ask. These are the headline forward-
-- looking "Road Ahead" numbers, exactly the kind of total a DSMB account could quietly inflate.
-- Same Pattern B pmc_size join as performance_cube.sql (via DIM_CRM_ACCOUNT_HISTORY.PMC_ID),
-- applied to all three underlying queries below (Part A, and both of Part B's subqueries).
--
-- NEW VERTICAL EXCLUDED (added 2026-08-05) -- per Kevin: "new verticals should not be
-- included anywhere in the dashboard" -- it has its own separate comp plan/tracking
-- (NEW_VERTICALS_PAYOUT), not part of this dashboard's core sales motion. Applied to all
-- three underlying queries below.
--
-- GARBAGE FAR-FUTURE DATE CAUGHT LIVE 2026-08-05 -- Kevin spotted a "2926-07" row on the Road
-- Ahead table. Confirmed live: real Salesforce data, a genuine typo on one line item
-- (ROLLOUT_MONTH = 2926-07-01, 1 unit -- someone fat-fingered the year, 2026 became 2926) --
-- not a query bug. This file's own {{ LookaheadMonths.value }} upper bound already excludes
-- it mathematically (2926 is nowhere close to a few months out) -- if it's still showing up
-- live, the widget isn't actually bound to this validated query/parameter, same "unverified
-- live widget" pattern as the Funnel Diagnosis incident (§4.5) -- check that binding first.
-- Added a second, absolute sanity ceiling anyway (`CURRENT_DATE() + 5 years`) as a defensive
-- backstop so a future fat-fingered year can never leak through even if LookaheadMonths is
-- ever misconfigured or left unbound -- cheap insurance, doesn't change any real near-term
-- number.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
)
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
LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
WHERE NOT o.IS_CLOSED
  AND o.OPPORTUNITY_TYPE != 'New Vertical'
  AND o.ANTICIPATED_GO_LIVE_AT_UTC >= CURRENT_DATE()
  AND o.ANTICIPATED_GO_LIVE_AT_UTC <= DATEADD(month, {{ LookaheadMonths.value }}, CURRENT_DATE())
  AND o.ANTICIPATED_GO_LIVE_AT_UTC <= DATEADD(year, 5, CURRENT_DATE())
  AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
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

-- Part B: COMBINED "Road Ahead" -- adds units from deals that have ALREADY closed but
-- haven't rolled out yet, using FCT_CRM_OPPORTUNITY_LINE_ITEM.ROLLOUT_MONTH, alongside the
-- open-pipeline forecast above. Per Kevin: "when a deal closed won theres an anticipated
-- rolled out month date - can we use that field to forecast future months?"
--
-- YES, validated live 2026-07-28 -- ROLLOUT_MONTH is assigned near deal-close time as a real
-- ANTICIPATED month, not left NULL until the property actually goes live (confirmed: 0 of
-- ~144K line items on deals closed in the last 3 months had a NULL ROLLOUT_MONTH). Checked
-- reliability by comparing predicted vs. actual outcome for line items whose predicted month
-- was 2-4 months ago (enough elapsed time to know the real outcome): 122,049 of 138,702
-- properties (88%) actually rolled out in their predicted month. The ~12% miss rate is
-- delays/failures -- the same population watchlist_large_deals_at_risk.sql flags.
--
-- CONFIDENCE GRADIENT, real and validated, not assumed: closed-but-awaiting-rollout units are
-- heavily concentrated in the VERY NEXT month (296,997 units expected next month, ~0 beyond
-- that -- matches the already-validated 12-day median close->rollout lag in
-- units_closed_forecast_bridge.sql) and carry real 88% historical accuracy. Open-pipeline
-- units (Part A above) are spread further out and carry no such accuracy backing (unweighted
-- face value on deals that haven't even closed yet). Bind these as two visually distinct
-- series on the same chart, don't blend them into one undifferentiated bar -- the near-term
-- number is meaningfully more trustworthy than the far-term one, and Sham should be able to
-- see that at a glance.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
)
SELECT
    COALESCE(c.expected_month, p.expected_month)     AS expected_month,
    COALESCE(c.units, 0)                             AS closed_awaiting_rollout_units,
    COALESCE(c.properties, 0)                        AS closed_awaiting_rollout_properties,
    COALESCE(p.units, 0)                             AS open_pipeline_units,
    COALESCE(p.deals, 0)                             AS open_pipeline_deals,
    COALESCE(c.units, 0) + COALESCE(p.units, 0)      AS total_expected_units
FROM (
    SELECT DATE_TRUNC('month', li.ROLLOUT_MONTH) AS expected_month,
        SUM(li.UNIT_COUNT) AS units, COUNT(*) AS properties
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM li
    JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON li.OPPORTUNITY_ID = o.OPPORTUNITY_ID
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED_WON
      AND o.OPPORTUNITY_TYPE != 'New Vertical'
      AND li.ROLLOUT_MONTH > CURRENT_DATE()
      AND li.ROLLOUT_MONTH <= DATEADD(month, {{ LookaheadMonths.value }}, CURRENT_DATE())
      AND li.ROLLOUT_MONTH <= DATEADD(year, 5, CURRENT_DATE())
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
    GROUP BY 1
) c
FULL OUTER JOIN (
    SELECT DATE_TRUNC('month', o.ANTICIPATED_GO_LIVE_AT_UTC) AS expected_month,
        SUM(o.FLEX_UNIT_COUNT) AS units, COUNT(*) AS deals
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE NOT o.IS_CLOSED
      AND o.OPPORTUNITY_TYPE != 'New Vertical'
      AND o.ANTICIPATED_GO_LIVE_AT_UTC > CURRENT_DATE()
      AND o.ANTICIPATED_GO_LIVE_AT_UTC <= DATEADD(month, {{ LookaheadMonths.value }}, CURRENT_DATE())
      AND o.ANTICIPATED_GO_LIVE_AT_UTC <= DATEADD(year, 5, CURRENT_DATE())
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
    GROUP BY 1
) p ON c.expected_month = p.expected_month
ORDER BY 1;
