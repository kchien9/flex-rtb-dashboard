-- NIRO (Non-Integrated Rolled Out) Units Cube — same shape as rolled_out_units_cube.sql,
-- for the new NIRO tab: which teams/reps/segments are carrying non-integrated units, across
-- which MSPs, trended over time. Kevin: "this is non integrated units. this should have
-- similar charts like which teams, reps, segments etc, across which msps. and trend analysis
-- too."
--
-- MSP DIMENSION IS DIFFERENT FROM EVERY OTHER FILE IN THIS REPO -- READ BEFORE REUSING THE
-- PATTERN ELSEWHERE. `PMS` on PROPERTY_BP_MONTH_STATS (the column every other MSP-sliced
-- query in this repo uses) is populated ONLY on already-integrated properties -- confirmed
-- live: every NIRO row (IS_ENGAGED AND NOT HAS_PAYMENT_INTEGRATION) has PMS = NULL. Can't
-- slice non-integrated units by MSP with that field. Fix: PRODUCTION.SALES.DIM_SALES_ACCOUNTS
-- .ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES (account-level, not property-level), joined via
-- HUBSPOT_COMPANY_ID = ACCOUNT_SALESFORCE_ID -- confirmed 1:1 (no duplicate
-- ACCOUNT_SALESFORCE_ID rows, so no fan-out risk) and populated for NIRO accounts with real
-- MSP names. This is the same field flex-comp-engine/ingestion/snowflake_pull.py's
-- pull_niro_units already uses. Computed once in `base` as `acct_pms`, alongside
-- segment_bucket/team_bucket, so the {{ Dimension.value }} dropdown stays a plain unqualified
-- column name like the rest of this repo's convention (segment_bucket / team_bucket /
-- HUBSPOT_DEAL_OWNER / acct_pms / HUBSPOT_DEAL_TYPE -- constrain the dropdown to exactly
-- these 5, same rule as rolled_out_units_cube.sql).
--
-- APPFOLIO -- DELIBERATELY NOT CARVED OUT (checked with Kevin 2026-08-04). The comp engine's
-- pull_niro_units excludes AppFolio-PMS accounts from NIRO entirely (treats AppFolio embed as
-- "payment-integrated, Yes Adjusted" for comp purposes). This dashboard does NOT apply that
-- carve-out -- Kevin's call, given AppFolio's lower strategic priority (see
-- docs/superblocks-setup.md §4.13): the raw embed-only gap is exactly the kind of thing worth
-- surfacing to Sham, not hiding. Expect AppFolio to show up as the single largest NIRO MSP by
-- a wide margin as a result (confirmed live, ~140K units, 2x+ the next biggest) -- that's
-- real, not a bug, and this dashboard's NIRO totals will disagree with the comp engine's
-- team_niro_units by roughly that amount. Documented so nobody "fixes" this later thinking
-- it's a bug.
--
-- NIRO METRIC: SUM(ENGAGED_UNITS) WHERE IS_ENGAGED AND NOT HAS_PAYMENT_INTEGRATION -- same
-- field pull_niro_units/pull_team_niro_units already use for this exact stock concept.
-- ENGAGED_UNITS, not PROPERTY_UNIT_COUNT -- they can differ when only part of a property is
-- actively engaged.
--
-- INTEGRATED_TOTAL_UNITS carried in the same row (IS_INTEGRATED_TOTAL, same stock flag
-- rolled_out_units_cube.sql already uses) so a mix-share % is computable without a second
-- query -- feeds insights_niro_mix_trend.sql's streak scanner and any Superblocks card that
-- wants "NIRO as % of total" directly.
--
-- Same DSMB exclusion (pmc_size, current live PMC total > 750 units), same departed-rep
-- exclusion (deal_owner_status + {{ GraceMonths.value }} grace period), same segment_bucket/
-- team_bucket mapping, and same apostrophe-escaping caveat on team names as
-- rolled_out_units_cube.sql -- see that file's header for the full writeup, not repeated here.
--
-- GRANULARITY built in from the start (unlike the first 7 scanners, which got it bolted on
-- later) -- {{ Granularity.value }} = 'Month' | 'Quarter', same DATE_TRUNC('quarter', BP_MONTH)
-- technique used throughout this repo.
--
-- STOCK VS FLOW -- caught live before shipping: niro_units and integrated_total_units are both
-- STOCK metrics (a per-BP_MONTH snapshot), same as insights_net_units_bridge.sql's
-- IS_INTEGRATED_TOTAL. A naive GROUP BY on the Quarter-truncated period sums 3 months of the
-- SAME stock value into one bucket, inflating every Quarter-grain number ~3x (confirmed live:
-- MM/Ent showed 348K-612K per quarter vs. ~126K-188K for any individual month in the same
-- window -- the tell-tale triple-count). Fixed with the same two-stage pattern
-- insights_net_units_bridge.sql already uses: aggregate to true BP_MONTH grain first
-- (`monthly_stock`), THEN roll up to the requested period via MAX_BY(value, BP_MONTH) --
-- picks the LAST month's already-correct value within the period instead of summing across
-- it. Month grain is unaffected by this bug (period already equals BP_MONTH 1:1) -- confirmed
-- unchanged before and after this fix.

WITH deal_owner_status AS (
    SELECT FULL_NAME, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT
        s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IS NULL THEN 'Not Set'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        acct.ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES AS acct_pms
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN PRODUCTION.SALES.DIM_SALES_ACCOUNTS acct
        ON s.HUBSPOT_COMPANY_ID = acct.ACCOUNT_SALESFORCE_ID
),
monthly_stock AS (
    -- True BP_MONTH grain -- a SUM here is a valid current snapshot (one row per property per
    -- BP_MONTH, no double-count). This is the stage that must NEVER be summed again across
    -- multiple BP_MONTHs -- see header.
    SELECT
        s.BP_MONTH,
        s.segment_bucket,
        s.team_bucket,
        COALESCE({{ Dimension.value }}, 'Not Set')                                    AS slice,
        SUM(IFF(s.IS_ENGAGED AND NOT s.HAS_PAYMENT_INTEGRATION, s.ENGAGED_UNITS, 0))   AS niro_units,
        SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0))                      AS integrated_total_units
    FROM base s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    LEFT JOIN deal_owner_status u ON u.FULL_NAME = s.HUBSPOT_DEAL_OWNER
    -- LookbackMonths needs a Superblocks component default (e.g. 6) -- see rolled_out_units_cube.sql.
    -- Resolved from MAX(BP_MONTH), not CURRENT_DATE() -- same reasoning as every other file here.
    WHERE s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }} * IFF('{{ Granularity.value }}' = 'Quarter', 3, 1), (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
      AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.segment_bucket IS NOT NULL
      AND (u.FULL_NAME IS NULL OR u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
      {{#Team.value}}     AND s.team_bucket = '{{Team.value}}'                       {{/Team.value}}
      {{#Msp.value}}       AND s.acct_pms = '{{Msp.value}}'                          {{/Msp.value}}
      {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE = '{{DealType.value}}'            {{/DealType.value}}
      {{#Segment.value}}   AND s.segment_bucket = '{{Segment.value}}'                {{/Segment.value}}
      {{#Rep.value}}        AND s.HUBSPOT_DEAL_OWNER = '{{Rep.value}}'               {{/Rep.value}}
    GROUP BY 1, 2, 3, 4
),
period_stock AS (
    -- Roll up to the requested period via MAX_BY(value, BP_MONTH) -- picks the LAST month's
    -- already-correct stock value within the period, never SUMs across it.
    SELECT
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', ms.BP_MONTH), ms.BP_MONTH) AS period,
        ms.segment_bucket,
        ms.team_bucket,
        ms.slice,
        MAX_BY(ms.niro_units, ms.BP_MONTH)             AS niro_units,
        MAX_BY(ms.integrated_total_units, ms.BP_MONTH) AS integrated_total_units
    FROM monthly_stock ms
    GROUP BY 1, 2, 3, 4
)
SELECT
    period,
    segment_bucket,
    team_bucket,
    slice,
    niro_units,
    integrated_total_units,
    DIV0(niro_units, niro_units + integrated_total_units) AS niro_share,
    -- MoM/QoQ change and a 3-period trailing average, same "was this period decent or just
    -- noisy" question as rolled_out_units_cube.sql's rolling_avg -- Granularity-aware since
    -- it operates on the already period-rolled-up `period_stock`, not raw BP_MONTH rows.
    niro_units - LAG(niro_units) OVER (PARTITION BY segment_bucket, team_bucket, slice ORDER BY period) AS niro_units_period_change,
    AVG(niro_units) OVER (PARTITION BY segment_bucket, team_bucket, slice ORDER BY period
                          ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)      AS niro_units_rolling_avg_3period
FROM period_stock
ORDER BY 1, 2, 3, 4;
