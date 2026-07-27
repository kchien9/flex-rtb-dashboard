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

WITH monthly AS (
    SELECT
        DATE_TRUNC('month', BP_MONTH) AS bp_month,
        HUBSPOT_COMPANY_SEGMENT       AS segment,
        PMS                            AS msp,
        SUM(IFF(IS_INTEGRATED_TOTAL, PROPERTY_UNIT_COUNT, 0)) AS units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH >= DATEADD(month, -3, DATE_TRUNC('month', CURRENT_DATE()))
      AND HUBSPOT_COMPANY_SEGMENT IS NOT NULL
      AND HUBSPOT_COMPANY_SEGMENT NOT IN ('No Company Units')
      AND PMS IS NOT NULL
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
WHERE bp_month = DATE_TRUNC('month', CURRENT_DATE())  -- current month only, for the live panel
  AND units_prior >= 20                                -- materiality floor: tune this
  AND ABS(pct_change) >= 0.15                          -- threshold: tune this
ORDER BY ABS(pct_change) DESC;

-- Same pattern also applies directly to recap vs. new (Sham's own example: "recapture units
-- are dropping relative to last month/week"). Swap the SUM(...) expression for
-- SUM(IFF(IS_RECAPTURED_NEW_ROLLOUT OR IS_RECAPTURED_OTHER, PROPERTY_UNIT_COUNT, 0))
-- and drop the msp/segment grouping if you want it network-wide, or keep them for
-- "recap units are dropping specifically in the SMB segment" granularity.
