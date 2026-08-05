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
-- FULLY-ELAPSED MONTHS ONLY -- BUG CAUGHT LIVE 2026-08-04: the first draft reused
-- closed_lost_analysis.sql Part B's exact censoring check (calendar month < BP month label) --
-- that mixes two different calendars and is wrong specifically in the early days of a calendar
-- month. Confirmed live: on 2026-08-05, DAY(CURRENT_DATE()) > 4 already flips the BP label to
-- Sep BP (2026-09-01), so "calendar month < 2026-09-01" let August 2026 -- 5 of 31 days in --
-- through as "complete." Every dimension immediately showed a dramatic, simultaneous
-- "streak" of 72-98% loss rates concentrated in that one barely-started month -- the classic
-- tiny-sample-looks-like-a-collapse artifact this repo's own censoring logic exists to
-- prevent, not something this file was supposed to reintroduce. Fixed to a pure calendar
-- check with no BP-label mixing at all: `DATE_TRUNC('month', CLOSED_AT_UTC) <
-- DATE_TRUNC('month', CURRENT_DATE())`. This is a pre-existing bug in `closed_lost_analysis.sql`
-- Part B too (same construction, copied from there) -- worth fixing there as well, flagged in
-- that file's own header where this cube's Part B logic gets consolidated.
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
-- data source -- the floor lives in the streak scanner (insights_closed_lost_streak.sql), same
-- split as rolled_out_units_cube.sql (unfloored) vs. its downstream scanners (floored).
--
-- Month/Quarter {{ Granularity.value }} toggle built in from the start.
--
-- MULTI-SELECT, added 2026-08-05 -- same change as rolled_out_units_cube.sql / niro_units_cube.
-- sql's own header writeup (same commit series, Debrief restructure): all 5 filters below
-- (Team/Segment/Msp/DealType/Rep) are now `IN ({{X.value}})`, not `= '{{X.value}}'`. The QUOTES
-- are no longer supplied by this file -- {{X.value}} must render as an already-quoted, comma-
-- separated list (e.g. Team.value -> 'Brandon''s Team' for one selection, 'Brandon''s
-- Team','Dana''s Team' for two), with every embedded apostrophe already doubled, before it
-- reaches this query. A single-value multi-select is regression-tested to behave identically
-- to the old single-dropdown `=` filter.
--
-- DUAL TIME COMPARISON, added 2026-08-05 (Debrief restructure, docs/superpowers/specs/2026-08-
-- 05-debrief-restructure-design.md, item 7) -- this file's plan entry is explicit that the
-- comparison belongs on the RATE (loss_rate_by_units), not on raw won/lost counts -- a rate and
-- a count are different things, and this file's own header above already explains why a raw
-- lost-deal count isn't the signal (it rides total deal volume). Added loss_rate_by_units_
-- prior_period (LAG of the rate itself) and loss_rate_by_units_trailing_avg_6period (ROWS
-- BETWEEN 6 PRECEDING AND 1 PRECEDING, EXCLUDING the current row so it's an independent
-- baseline, not double-counting the row it's being compared against -- same reasoning as
-- rolled_out_units_cube.sql's new_integrated_units_trailing_avg_6mo and niro_units_cube.sql's
-- niro_units_trailing_avg_6period). Named "_6period", not "_6mo", because this file's period
-- column can be Month OR Quarter ({{ Granularity.value }}), matching niro_units_cube.sql's
-- naming convention rather than rolled_out's month-specific one. This file had no pre-existing
-- window function to extend (unlike the other two cubes) -- built fresh directly on
-- loss_rate_by_units per the plan's explicit instruction.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
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
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e
        ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE AND e.SOURCE_SYSTEM = 'salesforce'
    LEFT JOIN user_dedup cr ON cr.FULL_NAME = e.FULL_NAME
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED
      AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND DATE_TRUNC('month', o.CLOSED_AT_UTC) < DATE_TRUNC('month', CURRENT_DATE())
      AND o.CLOSED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1), DATE_TRUNC('month', CURRENT_DATE()))
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
         SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0)))             AS loss_rate_by_units,
    -- Dual time comparison (see header) -- extends loss_rate_by_units, the rate itself, per
    -- the plan's explicit instruction not to substitute raw won/lost counts. Expression is
    -- recomputed inside LAG/AVG rather than referencing the loss_rate_by_units alias, and
    -- PARTITION BY/ORDER BY recompute the slice/period expressions rather than referencing
    -- those aliases -- same convention rolled_out_units_cube.sql/niro_units_cube.sql already
    -- established for window functions layered on top of a GROUP BY in this repo.
    LAG(DIV0(SUM(IFF(NOT IS_CLOSED_WON, FLEX_UNIT_COUNT, 0)),
             SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0))))
        OVER (PARTITION BY segment_bucket, team_bucket, COALESCE({{ Dimension.value }}, 'Not Set')
              ORDER BY IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', DATE_TRUNC('month', CLOSED_AT_UTC)), DATE_TRUNC('month', CLOSED_AT_UTC)))
                                                                                 AS loss_rate_by_units_prior_period,
    AVG(DIV0(SUM(IFF(NOT IS_CLOSED_WON, FLEX_UNIT_COUNT, 0)),
             SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0))))
        OVER (PARTITION BY segment_bucket, team_bucket, COALESCE({{ Dimension.value }}, 'Not Set')
              ORDER BY IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', DATE_TRUNC('month', CLOSED_AT_UTC)), DATE_TRUNC('month', CLOSED_AT_UTC))
              ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING)                        AS loss_rate_by_units_trailing_avg_6period
FROM scoped
WHERE segment_bucket IS NOT NULL
  {{#Team.value}}     AND team_bucket IN ({{Team.value}})         {{/Team.value}}
  {{#Segment.value}}  AND segment_bucket IN ({{Segment.value}})   {{/Segment.value}}
  {{#Msp.value}}       AND msp IN ({{Msp.value}})                  {{/Msp.value}}
  {{#DealType.value}}  AND deal_type IN ({{DealType.value}})       {{/DealType.value}}
  {{#Rep.value}}        AND rep IN ({{Rep.value}})                  {{/Rep.value}}
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4;
