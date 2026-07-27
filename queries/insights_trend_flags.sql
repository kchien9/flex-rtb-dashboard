-- Insights Engine, Part 1: Trend flags (spikes/dips vs. prior period)
-- Rule-based, not statistical (matches Kevin's "interpretability over accuracy" standard) --
-- flags a slice when |% change| clears a threshold AND the prior-period volume clears a
-- materiality floor (so a segment/MSP combo with 5 units swinging to 10 doesn't get
-- flagged as "+100%"). Tune MATERIALITY_FLOOR and PCT_THRESHOLD per how noisy Sham finds it.
--
-- Validated against live Snowflake 2026-07-27 -- real example output:
--   "Deep SMB segment's MRI Resident Portal units down 78% vs last month (737 -> 160 units)"
--   "Strategic segment's Rentmanager units up 162% vs last month (8788 -> 22982 units)"
--
-- TODO before shipping: exclude junk segment values ('No Company Units'); this draft run
-- surfaced them, need a WHERE segment NOT IN (...) filter once the full junk-value list is known.
--
-- BUG CAUGHT ON REVIEW (fixed below): the original draft compared
-- `bp_month = DATE_TRUNC('month', CURRENT_DATE())` to mean "current month" -- but BP_MONTH is
-- stored as the first-of-calendar-month of the month the BP ENDS in, and today's BP month
-- (Aug BP 2026, Jul 5 -> Aug 4) has BP_MONTH = 2026-08-01, not 2026-07-01. Comparing against
-- DATE_TRUNC('month', CURRENT_DATE()) = 2026-07-01 would silently select the PRIOR, already-
-- closed BP month instead of the current in-progress one -- one BP month stale, every time.
-- Fixed by resolving "current" from the data itself (MAX(BP_MONTH)) instead of CURRENT_DATE().
--
-- FILTER ESCAPING -- {{ Segment.value }} below narrows the scan (e.g. "only flag things in
-- Strategic"). Same apostrophe-breaking risk as every other value filter in this repo if a
-- segment name ever contains one -- none currently do, but don't assume that holds forever;
-- prefer Superblocks bind parameters over raw Mustache substitution here too.
--
-- DSMB EXCLUSION (base filter, permanent) -- same rule as rolled_out_units_cube.sql: exclude
-- PMCs whose CURRENT live unit total is <=750, by account size only, never by segment label
-- or team ownership (both tested against real data and don't reliably match "DSMB"). See that
-- file for the full writeup of why.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT
        DATE_TRUNC('month', s.BP_MONTH) AS bp_month,
        s.HUBSPOT_COMPANY_SEGMENT       AS segment,
        s.PMS                            AS msp,
        SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0)) AS units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.BP_MONTH >= DATEADD(month, -3, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
      AND s.HUBSPOT_COMPANY_SEGMENT IS NOT NULL
      AND s.HUBSPOT_COMPANY_SEGMENT NOT IN ('No Company Units')
      AND s.PMS IS NOT NULL
      AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      {{#Segment.value}} AND s.HUBSPOT_COMPANY_SEGMENT = '{{Segment.value}}' {{/Segment.value}}
      {{#Team.value}}    AND s.HUBSPOT_STATIC_TEAM_NAME_DEAL = '{{Team.value}}' {{/Team.value}}
    GROUP BY 1, 2, 3
),
with_change AS (
    SELECT
        *,
        LAG(units) OVER (PARTITION BY segment, msp ORDER BY bp_month) AS units_prior,
        DIV0(units - LAG(units) OVER (PARTITION BY segment, msp ORDER BY bp_month),
             LAG(units) OVER (PARTITION BY segment, msp ORDER BY bp_month)) AS pct_change
    FROM monthly
)
SELECT
    segment, msp, bp_month, units, units_prior, pct_change,
    segment || ' segment''s ' || msp || ' units ' ||
        IFF(pct_change < 0, 'down ', 'up ') ||
        ROUND(ABS(pct_change) * 100, 0) || '% vs last month (' ||
        units_prior || ' -> ' || units || ' units)'                   AS callout
FROM with_change
WHERE bp_month = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)  -- current BP month, resolved from data not CURRENT_DATE()
  AND units_prior >= 20                                -- materiality floor: tune this
  AND ABS(pct_change) >= 0.15                          -- threshold: tune this
ORDER BY ABS(pct_change) DESC;

-- Same pattern also applies directly to recap vs. new (Sham's own example: "recapture units
-- are dropping relative to last month/week"). Swap the SUM(...) expression for
-- SUM(IFF(IS_RECAPTURED_NEW_ROLLOUT OR IS_RECAPTURED_OTHER, PROPERTY_UNIT_COUNT, 0))
-- and drop the msp/segment grouping if you want it network-wide, or keep them for
-- "recap units are dropping specifically in the SMB segment" granularity.
