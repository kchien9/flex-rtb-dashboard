-- Closed Lost Rate Cube -- one-query-drives-every-slice pattern (same {{ Dimension.value }}
-- technique as rolled_out_units_cube.sql / niro_units_cube.sql), for Kevin's ask: "show closed
-- lost by segment, by msp, by deal type, by rep... make it % so it takes into consideration
-- the volume of opps." Consolidates and generalizes closed_lost_analysis.sql's Part B (segment,
-- trended) and Part C (rep, one trailing total) into one cube, extended to also cover MSP and
-- Deal Type -- the two dimensions Kevin explicitly asked for that had no coverage anywhere.
--
-- RATE, NOT RAW COUNT -- same principle closed_lost_analysis.sql's own header already
-- established: raw lost-deal count rises and falls with total deal volume, which isn't the
-- signal. Both loss_rate_by_deals and loss_rate_by_units are output -- units is the primary
-- number (this dashboard is about units throughout), but a single large lost deal can swing
-- it hard, so deal count sits right next to it, same "don't report one without the other"
-- rule as closed_lost_analysis.sql.
--
-- CALENDAR MONTH, NOT BP MONTH -- same as closed_lost_analysis.sql/insights_closed_lost_trend.sql:
-- deal closing is a Salesforce-native event, not a rollout event, so there's no BP-alignment
-- reason to use the BP calendar here. The BP calendar IS still used, but only as a completeness
-- gate (see below), not as the grouping grain.
--
-- FULLY-ELAPSED MONTHS ONLY -- reuses closed_lost_analysis.sql Part B's exact censoring
-- pattern: a calendar month only counts once it's strictly before the CURRENT BP month label,
-- so an in-progress month's single-digit closed-deal count never reads as a rate collapse.
--
-- MSP via PARTNER_MANAGEMENT_SOFTWARE (deal-grain) -- same field insights_declining_streaks.sql
-- Part B already validated for MSP pipeline analysis. Rep via OWNER_SK -> DIM_EMPLOYEE_HISTORY,
-- same resolution closed_lost_analysis.sql Part C already uses ("who owned THIS closed deal,"
-- a real per-record fact, not the deal-level team tag's known bulk-attribution artifact on OPEN
-- deals -- that caveat is specific to open pipeline, doesn't apply to closed deals here).
--
-- DEPARTED-REP FILTER SCOPED TO THE REP DIMENSION ONLY -- lesson learned building
-- niro_units_cube.sql: a rep-status filter applied uniformly corrupts non-rep aggregates (it
-- silently dropped 14-18% of real stock there). Kevin's standing rule ("i dont want to see
-- inactive users... in any table") is specifically about REP-LEVEL views, matching
-- closed_lost_analysis.sql Part C's already-shipped behavior -- so here the grace-period check
-- only applies WHEN `{{ Dimension.value }}` = 'rep' (a plain string-literal comparison against
-- the same raw Mustache substitution used for the dimension itself), and is a no-op for every
-- other dimension so segment/team/MSP/deal-type totals never shrink because of it.
--
-- Same DSMB exclusion (Pattern B via DIM_CRM_ACCOUNT_HISTORY.PMC_ID) as performance_cube.sql/
-- closed_lost_analysis.sql. No materiality floor in this cube itself -- this is the raw-detail
-- data source; the floor lives in the streak scanner (insights_closed_lost_streak.sql), same
-- split as rolled_out_units_cube.sql (unfloored) vs. its downstream scanners (floored).
--
-- Month/Quarter {{ Granularity.value }} toggle built in from the start.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
user_dedup AS (
    SELECT FULL_NAME, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
scoped AS (
    SELECT
        o.*,
        e.FULL_NAME AS rep,
        cr.IS_ACTIVE, cr.LAST_LOGIN_AT_UTC,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        COALESCE(o.PARTNER_MANAGEMENT_SOFTWARE, 'Not Set') AS msp,
        o.OPPORTUNITY_TYPE AS deal_type
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    CROSS JOIN current_bp
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e
        ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE AND e.SOURCE_SYSTEM = 'salesforce'
    LEFT JOIN user_dedup cr ON cr.FULL_NAME = e.FULL_NAME
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED
      AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND DATE_TRUNC('month', o.CLOSED_AT_UTC) < current_bp.bp_month_label
      AND o.CLOSED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1), current_bp.bp_month_label)
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      -- departed-rep grace check: only bites when slicing by rep, see header
      AND (NOT ('{{ Dimension.value }}' = 'rep') OR cr.FULL_NAME IS NULL OR cr.IS_ACTIVE
           OR cr.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
)
SELECT
    IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', DATE_TRUNC('month', CLOSED_AT_UTC)), DATE_TRUNC('month', CLOSED_AT_UTC)) AS period,
    segment_bucket,
    team_bucket,
    COALESCE({{ Dimension.value }}, 'Not Set')                                  AS slice,
    COUNT(*)                                                                    AS total_closed_deals,
    SUM(IFF(IS_CLOSED_WON, 1, 0))                                               AS deals_won,
    SUM(IFF(NOT IS_CLOSED_WON, 1, 0))                                           AS deals_lost,
    DIV0(SUM(IFF(NOT IS_CLOSED_WON, 1, 0)), COUNT(*))                           AS loss_rate_by_deals,
    SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0))                   AS total_closed_units,
    SUM(IFF(IS_CLOSED_WON, FLEX_UNIT_COUNT, 0))                                 AS units_won,
    SUM(IFF(NOT IS_CLOSED_WON, FLEX_UNIT_COUNT, 0))                             AS units_lost,
    DIV0(SUM(IFF(NOT IS_CLOSED_WON, FLEX_UNIT_COUNT, 0)),
         SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0)))             AS loss_rate_by_units
FROM scoped
WHERE segment_bucket IS NOT NULL
  {{#Team.value}}     AND team_bucket = '{{Team.value}}'         {{/Team.value}}
  {{#Segment.value}}  AND segment_bucket = '{{Segment.value}}'   {{/Segment.value}}
  {{#Msp.value}}       AND msp = '{{Msp.value}}'                  {{/Msp.value}}
  {{#DealType.value}}  AND deal_type = '{{DealType.value}}'       {{/DealType.value}}
  {{#Rep.value}}        AND rep = '{{Rep.value}}'                  {{/Rep.value}}
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4;
