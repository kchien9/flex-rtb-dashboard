-- Rolled-Out Units Cube — recap vs. new, MSP, segment, team, deal type, by month
-- Feeds the monthly lookback page. STAYS ON OLD TABLE — no new-platform (FLEX.*) equivalent
-- exists yet for the rollout/recap/tier/MSP/segment flags. See docs/replatform-notes.md.
-- {{ Dimension.value }} is a Superblocks dropdown bound to a column name, so one query
-- drives every slice (PMS / HUBSPOT_DEAL_TYPE / HUBSPOT_COMPANY_SEGMENT /
-- HUBSPOT_STATIC_TEAM_NAME_DEAL / HUBSPOT_DEAL_OWNER).

SELECT
    DATE_TRUNC('month', BP_MONTH)                AS bp_month,
    {{ Dimension.value }}                        AS slice,
    SUM(IFF(IS_INTEGRATED_TOTAL, PROPERTY_UNIT_COUNT, 0))          AS integrated_total_units,
    SUM(IFF(IS_NEW_INTEGRATED, PROPERTY_UNIT_COUNT, 0))            AS new_integrated_units,
    SUM(IFF(IS_RECAPTURED_NEW_ROLLOUT OR IS_RECAPTURED_OTHER,
            PROPERTY_UNIT_COUNT, 0))                               AS recaptured_units,
    SUM(IFF(IS_NEW_ROLLOUT AND NOT IS_RECAPTURED_NEW_ROLLOUT
            AND NOT IS_RECAPTURED_OTHER, PROPERTY_UNIT_COUNT, 0))   AS new_units,
    SUM(IFF(IS_DEACTIVATED, PROPERTY_UNIT_COUNT, 0))               AS deactivated_units,
    SUM(ROLLED_OUT_UNITS_MOM_CHANGE)                                AS net_change_units
FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
WHERE BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, DATE_TRUNC('month', CURRENT_DATE()))
  {{#Team.value}}     AND HUBSPOT_STATIC_TEAM_NAME_DEAL = '{{Team.value}}'    {{/Team.value}}
  {{#Msp.value}}       AND PMS = '{{Msp.value}}'                              {{/Msp.value}}
  {{#DealType.value}}  AND HUBSPOT_DEAL_TYPE = '{{DealType.value}}'           {{/DealType.value}}
GROUP BY 1, 2
ORDER BY 1, 2;
