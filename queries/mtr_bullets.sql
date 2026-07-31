-- MTR Bullets: biggest deal + healthiest trend, per Kevin's own call to keep this simple --
-- no causal "why" reasoning (that needs data we don't have, see project memory), just the
-- two things that are cleanly, honestly auto-generatable: what's the best win, what's
-- trending well. Feeds the "worth celebrating" side of the Week/Month/Quarter Summary.
--
-- BUG CAUGHT ON TESTING: `ORDER BY units DESC` alone put a NULL-unit deal (a non-PMC
-- insurance-type opportunity) ahead of the actual biggest real deal -- Snowflake defaults to
-- NULLS FIRST on DESC. Fixed with an explicit IS NOT NULL filter before ranking; don't drop
-- that filter when extending this query.
--
-- DSMB EXCLUSION ADDED 2026-07-31 -- this file had NO account-size filter at all (caught in a
-- repo-wide DSMB audit per Kevin's explicit ask: "make sure DSMB is not included anywhere...
-- in no ai summaries"). This feeds the AI-generated "worth celebrating" narrative directly, so
-- a DSMB deal or a DSMB-driven trend could get literally read out to Sham. Unlikely to ever
-- change Part A's top-3 in practice (a DSMB account's single deal is rarely the single biggest
-- close company-wide), but "unlikely to matter" isn't the same as "correctly excluded" -- same
-- pmc_size pattern as everywhere else in this repo (Pattern B via DIM_CRM_ACCOUNT_HISTORY for
-- Part A's deal-grain table, Pattern A directly for Part B's PROPERTY_BP_MONTH_STATS table).

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
)
-- Part A: biggest deal closed this period
SELECT
    o.OPPORTUNITY_NAME                                              AS deal,
    o.FLEX_UNIT_COUNT                                                AS units,
    a.ACCOUNT_NAME                                                   AS pmc,
    'Landed ' || o.OPPORTUNITY_NAME ||
        ' -- ' || o.FLEX_UNIT_COUNT || ' units' ||
        IFF(a.ACCOUNT_NAME IS NOT NULL, ' (' || a.ACCOUNT_NAME || ')', '')  AS callout
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
WHERE o.IS_CLOSED_WON
  AND o.FLEX_UNIT_COUNT IS NOT NULL
  AND o.CLOSED_AT_UTC BETWEEN {{ ThisPeriodStart }} AND {{ ThisPeriodEnd }}
  AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
ORDER BY o.FLEX_UNIT_COUNT DESC
LIMIT 3;

-- Part B: healthiest trend this period (biggest positive % move, same materiality gate as
-- insights_trend_flags.sql so this doesn't celebrate a 5-unit segment doubling to 10)
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT DATE_TRUNC('month', s.BP_MONTH) AS bp_month, s.HUBSPOT_COMPANY_SEGMENT AS segment, s.PMS AS msp,
        SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.BP_MONTH >= DATEADD(month, -2, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
      AND s.HUBSPOT_COMPANY_SEGMENT IS NOT NULL AND s.HUBSPOT_COMPANY_SEGMENT NOT IN ('No Company Units') AND s.PMS IS NOT NULL
      AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
    GROUP BY 1, 2, 3
)
SELECT
    segment, msp, bp_month, units, units_prior, pct_change,
    segment || ' segment''s ' || msp || ' units up ' || ROUND(pct_change * 100, 0) ||
        '% vs last month (' || units_prior || ' -> ' || units || ' units)' AS callout
FROM (
    SELECT *,
        LAG(units) OVER (PARTITION BY segment, msp ORDER BY bp_month) AS units_prior,
        DIV0(units - LAG(units) OVER (PARTITION BY segment, msp ORDER BY bp_month),
             LAG(units) OVER (PARTITION BY segment, msp ORDER BY bp_month)) AS pct_change
    FROM monthly
)
WHERE bp_month = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
  AND units_prior >= 20
  AND pct_change > 0
ORDER BY pct_change DESC
LIMIT 3;
