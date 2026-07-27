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

SELECT
    DATE_TRUNC('month', BP_MONTH)                          AS bp_month,
    COALESCE({{ Dimension.value }}, 'Not Set')             AS slice,
    SUM(IFF(IS_INTEGRATED_TOTAL, PROPERTY_UNIT_COUNT, 0))          AS integrated_total_units,
    SUM(IFF(IS_NEW_INTEGRATED, PROPERTY_UNIT_COUNT, 0))            AS new_integrated_units,
    SUM(IFF(IS_RECAPTURED_NEW_ROLLOUT OR IS_RECAPTURED_OTHER,
            PROPERTY_UNIT_COUNT, 0))                               AS recaptured_units,
    SUM(IFF(IS_NEW_ROLLOUT AND NOT IS_RECAPTURED_NEW_ROLLOUT
            AND NOT IS_RECAPTURED_OTHER, PROPERTY_UNIT_COUNT, 0))   AS new_units,
    SUM(IFF(IS_DEACTIVATED, PROPERTY_UNIT_COUNT, 0))               AS deactivated_units,
    SUM(ROLLED_OUT_UNITS_MOM_CHANGE)                                AS net_change_units
FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
-- LookbackMonths needs a Superblocks component default (e.g. 6) -- if this binding is ever
-- empty, DATEADD(month, -, ...) is a syntax error, not a "no filter applied" no-op.
WHERE BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, DATE_TRUNC('month', CURRENT_DATE()))
  {{#Team.value}}     AND HUBSPOT_STATIC_TEAM_NAME_DEAL = '{{Team.value}}'      {{/Team.value}}
  {{#Msp.value}}       AND PMS = '{{Msp.value}}'                                {{/Msp.value}}
  {{#DealType.value}}  AND HUBSPOT_DEAL_TYPE = '{{DealType.value}}'             {{/DealType.value}}
  {{#Segment.value}}   AND HUBSPOT_COMPANY_SEGMENT = '{{Segment.value}}'        {{/Segment.value}}
  {{#Rep.value}}        AND HUBSPOT_DEAL_OWNER = '{{Rep.value}}'                {{/Rep.value}}
GROUP BY 1, 2
ORDER BY 1, 2;
