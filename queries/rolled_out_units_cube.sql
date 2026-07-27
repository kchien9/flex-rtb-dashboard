-- Rolled-Out Units Cube — recap vs. new, MSP, segment, team, deal type, by month
-- Feeds the monthly lookback page. STAYS ON OLD TABLE — no new-platform (FLEX.*) equivalent
-- exists yet for the rollout/recap/tier/MSP/segment flags. See docs/replatform-notes.md.
--
-- {{ Dimension.value }} is a Superblocks dropdown bound to a column name, so one query
-- drives every slice (PMS / HUBSPOT_DEAL_TYPE / HUBSPOT_COMPANY_SEGMENT /
-- HUBSPOT_STATIC_TEAM_NAME_DEAL / HUBSPOT_DEAL_OWNER). Constrain this dropdown's options to
-- exactly those 5 values in Superblocks -- it's a raw SQL identifier substitution, not a
-- value, so it can't be parameterized like the filters below. Never let it be free text.
--
-- FILTER ESCAPING -- READ BEFORE WIRING: real team names contain apostrophes
-- ("Brandon's Team", "Cory's Team") which BREAK naive '{{Value}}' string interpolation --
-- confirmed live: `... = 'Brandon's Team'` is a SQL syntax error, not a hypothetical.
-- Prefer Superblocks' native bind-parameter syntax for the Snowflake connector (properly
-- escaped by the driver) over raw Mustache string substitution for every value filter below.
-- If only Mustache is available, the filter value must have its apostrophes doubled before
-- it reaches this query (e.g. in the component's transform, value.replace("'", "''")) --
-- verified fix: '{{Team.value}}' -> 'Brandon''s Team' resolves and runs correctly.
--
-- All 5 slice-able dimensions are filterable here so they can be layered together (e.g.
-- Team + MSP + DealType at once, per Kevin's "provide detail to the lowest level of
-- granularity" ask) -- not just the dimension currently selected as the row grouping.
--
-- DSMB EXCLUSION (base filter, permanent, not a toggle) -- confirmed 2026-07-27: this whole
-- dashboard is scoped to SMB+, DSMB excluded. DSMB is defined by ACCOUNT SIZE (a PMC with
-- <=750 total units), NOT by segment label or team ownership -- both of those were tested
-- against real data and don't hold: HUBSPOT_COMPANY_SEGMENT = 'Deep SMB' includes 2,024 rows
-- with >750 units (some over 100k), and plenty of "SMB"-segment rows are <=750 units. Also
-- confirmed OK on purpose: an SMB rep can carry a DSMB-sized account in their book (legacy
-- from before a workstream migration) -- exclusion is by ACCOUNT SIZE only, never by which
-- rep/team owns the deal.
-- Uses each PMC's CURRENT live unit total (summed fresh below), not the stored
-- HUBSPOT_DEAL_TOTAL_COMPANY_UNITS field -- that field is a deal-time snapshot and disagrees
-- with current reality on ~13% of PMCs (267 of 2,011 tested), which matters for a dashboard
-- that's supposed to reflect right-now, not whatever a HubSpot deal property said when it
-- was last touched.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
)
SELECT
    DATE_TRUNC('month', s.BP_MONTH)                          AS bp_month,
    COALESCE({{ Dimension.value }}, 'Not Set')               AS slice,
    SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0))          AS integrated_total_units,
    SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0))            AS new_integrated_units,
    SUM(IFF(s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER,
            s.PROPERTY_UNIT_COUNT, 0))                                 AS recaptured_units,
    SUM(IFF(s.IS_NEW_ROLLOUT AND NOT s.IS_RECAPTURED_NEW_ROLLOUT
            AND NOT s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0))   AS new_units,
    SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0))               AS deactivated_units,
    SUM(s.ROLLED_OUT_UNITS_MOM_CHANGE)                                  AS net_change_units
FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
-- LookbackMonths needs a Superblocks component default (e.g. 6) -- if this binding is ever
-- empty, DATEADD(month, -, ...) is a syntax error, not a "no filter applied" no-op.
-- Resolved from MAX(BP_MONTH), not CURRENT_DATE() -- calendar month != current BP month
-- (e.g. 2026-07-27 sits inside "Aug BP 2026") -- same bug class fixed elsewhere in this repo.
WHERE s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
  -- DSMB exclusion: only drop a PMC when we can affirmatively confirm it's <=750 units.
  -- p.pmc_current_units IS NULL means the PMC has no in-network rows this month (e.g. fully
  -- deactivated) -- don't silently drop those, that's a different question than DSMB sizing.
  AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
  {{#Team.value}}     AND s.HUBSPOT_STATIC_TEAM_NAME_DEAL = '{{Team.value}}'      {{/Team.value}}
  {{#Msp.value}}       AND s.PMS = '{{Msp.value}}'                                {{/Msp.value}}
  {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE = '{{DealType.value}}'             {{/DealType.value}}
  {{#Segment.value}}   AND s.HUBSPOT_COMPANY_SEGMENT = '{{Segment.value}}'        {{/Segment.value}}
  {{#Rep.value}}        AND s.HUBSPOT_DEAL_OWNER = '{{Rep.value}}'                {{/Rep.value}}
GROUP BY 1, 2
ORDER BY 1, 2;
