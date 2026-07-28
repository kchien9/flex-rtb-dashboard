-- Mix Shift Pulse -- is the COMPOSITION of what we're rolling out changing in a risky way,
-- not just the total. Per Kevin: "sham wants to have a pulse on ALL of these dimensions. are
-- we shifting too far into expansion, over-leaning into one MSP, too many recaptures, etc."
-- One query, three share-of-total trends over the same trailing window, all DSMB-excluded and
-- new-rollout-scoped so it reads on the same base as rolled_out_units_cube.sql:
--   1. expansion_share  -- Expansion units / total new-rollout units (New Logo vs Expansion mix)
--   2. recapture_share  -- recaptured units / total (too many recaptures = growth coming from
--      re-signing churned accounts, not real net-new expansion of the network)
--   3. top_msp_share    -- largest single MSP's share of total (are we over-concentrated in
--      one PMS, which is a real risk if that PMS relationship or integration ever breaks)
--
-- SHARE, NOT ABSOLUTE -- same reasoning as the closed-lost rate query: absolute expansion
-- units go up when total volume goes up, that's not a mix signal. Share isolates whether the
-- COMPOSITION is drifting, independent of overall growth or contraction.
--
-- Stays on PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS -- same table as
-- rolled_out_units_cube.sql, no new-platform equivalent for recapture/deal-type flags yet.
-- HUBSPOT_DEAL_TYPE and the recapture booleans validated live 2026-07-27.
--
-- MSP CONCENTRATION -- validated live: top_msp_share (always Yardi in the trailing window)
-- runs ~36-50% of new-rollout units per BP month. First draft of this query joined the
-- per-PMS monthly total (msp_by_month, one row per BP_MONTH x PMS) straight to `base` on
-- BP_MONTH alone -- that fans out every base row once per distinct PMS seen that month (7-8x),
-- inflating total_units ~7x and silently corrupting every share in the query, not just
-- top_msp_share. Fixed by collapsing to one row per month FIRST (top_msp_per_month, via
-- QUALIFY msp_units = MAX(...) OVER (PARTITION BY BP_MONTH)) and joining that to `base` --
-- matches Snowflake's clause order too (QUALIFY has to come after GROUP BY in the same
-- SELECT, so it can't sit in the same query as the final aggregation; it needs its own CTE).
--
-- DSMB EXCLUSION -- same pmc_size CTE pattern as rolled_out_units_cube.sql (current live PMC
-- unit total <=750, not segment label, not team ownership). See that file's header for the
-- full rationale.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT
        s.BP_MONTH,
        s.HUBSPOT_DEAL_TYPE,
        s.PMS,
        s.PROPERTY_UNIT_COUNT,
        (s.IS_RECAPTURED_OTHER OR s.IS_RECAPTURED_NEW_ROLLOUT
         OR s.IS_NON_INTEGRATED_RECAPTURED_OTHER OR s.IS_NON_INTEGRATED_RECAPTURED_NEW_ROLLOUT) AS is_recapture
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.IS_NEW_ROLLOUT
      AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
      {{#Team.value}}    AND s.HUBSPOT_STATIC_TEAM_NAME_DEAL = '{{Team.value}}' {{/Team.value}}
),
msp_by_month AS (
    SELECT BP_MONTH, PMS, SUM(PROPERTY_UNIT_COUNT) AS msp_units
    FROM base
    GROUP BY 1, 2
),
top_msp_per_month AS (
    -- one row per BP_MONTH -- this is what avoids the fan-out described above
    SELECT BP_MONTH, PMS AS top_msp, msp_units AS top_msp_units
    FROM msp_by_month
    QUALIFY msp_units = MAX(msp_units) OVER (PARTITION BY BP_MONTH)
)
SELECT
    b.BP_MONTH,
    SUM(b.PROPERTY_UNIT_COUNT)                                                          AS total_units,
    DIV0(SUM(IFF(b.HUBSPOT_DEAL_TYPE = 'Expansion', b.PROPERTY_UNIT_COUNT, 0)),
         SUM(b.PROPERTY_UNIT_COUNT))                                                     AS expansion_share,
    DIV0(SUM(IFF(b.is_recapture, b.PROPERTY_UNIT_COUNT, 0)), SUM(b.PROPERTY_UNIT_COUNT))  AS recapture_share,
    MAX(t.top_msp)                                                                        AS top_msp,
    DIV0(MAX(t.top_msp_units), SUM(b.PROPERTY_UNIT_COUNT))                                AS top_msp_share
FROM base b
JOIN top_msp_per_month t ON b.BP_MONTH = t.BP_MONTH
GROUP BY 1
ORDER BY 1;
