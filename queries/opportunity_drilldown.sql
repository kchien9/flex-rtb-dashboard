-- Opportunity Drill-Down -- the bottom of every drill chain. Per Kevin: "i want the units to
-- have opportunity drill downs too. so when you drill into a rep i want to see the deals that
-- drive everything." Rolled-Out Units lives at PROPERTY grain (PROPERTY_BP_MONTH_STATS), which
-- is right for the top-level cube but not what a sales leader wants to see when they click all
-- the way down to a rep -- they want the actual DEALS, not a list of individual properties.
--
-- One query, filterable by every dimension already used elsewhere in this repo (Rep / Team /
-- BP month / Deal Type) so it can sit underneath ANY slice in rolled_out_units_cube.sql or
-- the rep leaderboard -- click a rep's bar, click a team's row, click a BP-month cell, all land
-- here with the corresponding filter set.
--
-- GRAIN: aggregated to OPPORTUNITY, not property line-item. FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM
-- is the bridge table used in units_closed_forecast_bridge.sql (deal-grain -> property-grain,
-- carries its own ROLLOUT_MONTH per property). A single opportunity can cover many properties
-- rolling out together (validated live: one Cory Baach expansion deal spanned 89 properties in
-- one BP month) -- summing to opportunity grain before display is what makes this a "here are
-- the deals" list instead of a 1000-row property list. Validated live 2026-07-27: Cory Baach's
-- opportunity-level rollup for last BP month sums to the same total (33,718 units) as his row
-- in rep_leaderboard.sql for the same period -- confirms the two views tie out.
--
-- FILTER ESCAPING -- same apostrophe risk as every value filter in this repo (see
-- rolled_out_units_cube.sql header). Team/Rep filters especially -- double apostrophes if
-- passing raw Mustache.
--
-- TEAM BUCKET (added 2026-07-28) -- same mapping used everywhere else in this repo, so the
-- Team filter behaves consistently when this drill-down sits underneath a Team-filtered
-- parent view. Note this table is joined via DIM_EMPLOYEE_HISTORY (rep-grain) -- same known
-- data-quality caveat as the Meetings query in performance_cube.sql.
--
-- SALESFORCE LINK -- opportunity_id is already in the SELECT list, this is the field to build
-- the deep link from in Superblocks: every row in this drill-down should be clickable.
--
-- INACTIVE/CROSS-TEAM LEAKAGE FIX (2026-07-29) -- same root cause and fix as
-- activity_vs_outcome_by_rep.sql's header. The employee join now goes through a deduped,
-- grace-period-aware team_map (Salesforce-sourced DIM_EMPLOYEE_HISTORY row -> deduped
-- STG_SALESFORCE__USER, PARENT_TEAM='Mid Market +' required for the Strategic pod,
-- {{ GraceMonths.value }} grace period) instead of joining DIM_EMPLOYEE_HISTORY directly.

WITH emp_dedup AS (
    SELECT EMPLOYEE_SK, EMAIL
    FROM FLEX.MART.DIM_EMPLOYEE_HISTORY
    WHERE SOURCE_SYSTEM = 'salesforce' AND IS_CURRENT = TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY UPDATED_AT_UTC DESC) = 1
),
user_dedup AS (
    SELECT EMAIL, FULL_NAME, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
team_map AS (
    SELECT ed.EMPLOYEE_SK, u.FULL_NAME, u.TEAM_NAME,
        CASE
            WHEN u.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN u.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN u.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN u.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND u.PARENT_TEAM = 'Mid Market +' THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM emp_dedup ed
    JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE())
)
SELECT
    o.OPPORTUNITY_NAME                                 AS opportunity,
    o.OPPORTUNITY_TYPE                                 AS deal_type,
    m.FULL_NAME                                        AS rep,
    m.TEAM_NAME                                        AS team,
    m.team_bucket,
    li.ROLLOUT_MONTH                                   AS bp_month,
    SUM(li.UNIT_COUNT)                                 AS units,
    COUNT(DISTINCT li.PROPERTY_ID)                     AS properties,
    o.CLOSED_AT_UTC                                    AS closed_date,
    o.OPPORTUNITY_ID                                   AS opportunity_id,
    -- Salesforce domain confirmed by Kevin 2026-07-29: getflex.lightning.force.com. Gated on
    -- the ID format -- this table blends Salesforce-native (18-char "006..." IDs) and
    -- HubSpot-origin (plain numeric) records same as open opportunities do (see
    -- open_opportunities_drilldown.sql's header) -- a numeric ID was never a Salesforce record,
    -- so the link must be NULL there, not a guaranteed-broken URL. Unlike the open-pipeline
    -- queries, legacy-ID rows are NOT excluded here -- these are already-closed, already-
    -- rolling-out deals (real revenue), not stale leads, so a HubSpot-origin ID just means the
    -- deal was created before the Salesforce migration, not that it isn't real.
    IFF(o.OPPORTUNITY_ID LIKE '006%',
        'https://getflex.lightning.force.com/lightning/r/Opportunity/' || o.OPPORTUNITY_ID || '/view',
        NULL) AS salesforce_url
FROM FLEX.SALES.FCT_CRM_OPPORTUNITY_LINE_ITEM li
JOIN team_map m ON li.OWNER_SK = m.EMPLOYEE_SK
LEFT JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON li.OPPORTUNITY_ID = o.OPPORTUNITY_ID
WHERE li.ROLLOUT_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
  {{#Rep.value}}       AND m.FULL_NAME = '{{Rep.value}}'         {{/Rep.value}}
  {{#Team.value}}      AND m.team_bucket = '{{Team.value}}' {{/Team.value}}
  {{#BpMonth.value}}   AND li.ROLLOUT_MONTH = '{{BpMonth.value}}' {{/BpMonth.value}}
  {{#DealType.value}}  AND o.OPPORTUNITY_TYPE = '{{DealType.value}}' {{/DealType.value}}
GROUP BY 1, 2, 3, 4, 5, 6, 9, 10, 11
ORDER BY units DESC;
