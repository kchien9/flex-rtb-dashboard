-- AI Summary Facts -- feeds the "Worth Knowing Right Now" AI-generated summary. Per Kevin:
-- replace the static Watch List teaser with a summary that reflects WHATEVER filters are
-- currently selected (period + team/segment/MSP/deal type), not a fixed set of deal-level
-- callouts -- "if we filter on this month and appfolio and strategic segment, the summary
-- reflects... driven by x rep or y deal."
--
-- THIS QUERY DOES NOT WRITE THE SUMMARY. It only gathers the facts an LLM call then narrates.
-- Keep those two steps separate -- this query returns numbers, a downstream LLM step (see
-- docs/superblocks-setup.md's AI Summary section) turns numbers into prose. Don't ask an LLM
-- to also compute the numbers itself -- that's how you get confidently wrong math.
--
-- Same base/filters as rolled_out_units_cube.sql (DSMB-excluded, segment_bucket/team_bucket/
-- PMS/HUBSPOT_DEAL_TYPE all filterable, same escaping caveats) -- this is deliberately the
-- SAME filter surface, so the AI summary always reflects exactly what's on screen, not a
-- separate parallel set of filters that could drift out of sync.
--
-- Part A: headline this-vs-last for the current filter combination.
-- Part B: top 3 drivers (reps) within that same filter combination, with each one's % of the
-- total -- this is what lets the LLM say "driven by X rep" instead of guessing.
-- Validated live 2026-07-28, Strategic segment + AppFolio: this_period 297 vs last_period 18
-- units (real, dramatic swing) -- Part B shows it's driven by Ariel Kurek (175, 59%) and
-- Jennette Sanchez (122, 41%), a 2-rep concentration worth naming explicitly, not just "the
-- Strategic team is up."

WITH pmc_size AS (
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
        END AS team_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.IS_NEW_INTEGRATED
      {{#Team.value}}     AND team_bucket = '{{Team.value}}'          {{/Team.value}}
      {{#Segment.value}}  AND segment_bucket = '{{Segment.value}}'   {{/Segment.value}}
      {{#Msp.value}}      AND PMS = '{{Msp.value}}'                  {{/Msp.value}}
      {{#DealType.value}} AND HUBSPOT_DEAL_TYPE = '{{DealType.value}}' {{/DealType.value}}
)
-- Part A: headline
--
-- ELAPSED-PERIOD AWARENESS ADDED 2026-08-04 -- Kevin caught a Superblocks-built "Funnel
-- Diagnosis" widget (NOT this file, confirmed by exact-number matching against a raw query)
-- comparing 4 calendar days (Aug 1-4) against the same 4 days last month, then narrating a
-- still-forming number as "a complete collapse." This file's period was never that specific
-- bug (BP_MONTH here already only contains whatever's actually happened, it's not
-- artificially truncated to a calendar slice) -- but it also never told the LLM how much of
-- the CURRENT BP month has elapsed, so nothing stopped a similar overstatement here either.
-- `bp_period_start`/`bp_period_end`/`days_elapsed`/`days_total_in_period` give the narration
-- step real temporal grounding regardless of which BP month is active -- the prompt rule in
-- docs/superblocks-setup.md §4.5 now requires checking this before calling any move a trend.
SELECT
    SUM(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), PROPERTY_UNIT_COUNT, 0)) AS this_period_units,
    SUM(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), PROPERTY_UNIT_COUNT, 0)) AS last_period_units,
    DIV0(
        SUM(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), PROPERTY_UNIT_COUNT, 0))
        - SUM(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), PROPERTY_UNIT_COUNT, 0)),
        SUM(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), PROPERTY_UNIT_COUNT, 0))
    ) AS pct_change,
    DATEADD(day, 4, DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))) AS bp_period_start,
    LEAST(DATEADD(day, 3, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), CURRENT_DATE()) AS bp_period_end,
    DATEDIFF(day, DATEADD(day, 4, DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))),
                  LEAST(DATEADD(day, 3, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), CURRENT_DATE())) + 1 AS days_elapsed,
    DATEDIFF(day, DATEADD(day, 4, DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))),
                  DATEADD(day, 3, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))) + 1 AS days_total_in_period
FROM base
WHERE BP_MONTH IN ((SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS),
                   DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)));

-- Part B: top 3 drivers within the SAME filter combination, this period only.
-- Separate statement -- needs its own copy of the pmc_size/base CTEs, Snowflake doesn't
-- share a WITH clause across two semicolon-delimited statements (caught while validating --
-- first draft referenced `base` here and failed with "Object 'BASE' does not exist").
WITH pmc_size AS (
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
        END AS team_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.IS_NEW_INTEGRATED
      {{#Team.value}}     AND team_bucket = '{{Team.value}}'          {{/Team.value}}
      {{#Segment.value}}  AND segment_bucket = '{{Segment.value}}'   {{/Segment.value}}
      {{#Msp.value}}      AND PMS = '{{Msp.value}}'                  {{/Msp.value}}
      {{#DealType.value}} AND HUBSPOT_DEAL_TYPE = '{{DealType.value}}' {{/DealType.value}}
)
SELECT
    HUBSPOT_DEAL_OWNER AS rep,
    SUM(PROPERTY_UNIT_COUNT) AS units,
    DIV0(SUM(PROPERTY_UNIT_COUNT), SUM(SUM(PROPERTY_UNIT_COUNT)) OVER ()) AS share_of_total
FROM base
WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
  AND HUBSPOT_DEAL_OWNER IS NOT NULL
GROUP BY 1
ORDER BY 2 DESC
LIMIT 3;

-- ================================================================================
-- Parts C-E added 2026-07-28 -- Kevin: "we need it to be intelligent... more than
-- just x rep closed this deal." Parts A/B answer "what moved." These answer "is it
-- real, is it explained, and is it part of a pattern" -- the difference between a
-- shallow highlight and something that actually changes what Sham does next.
--
-- GRAIN NOTE: Parts C/D are deal-grain (FCT_CRM_OPPORTUNITY, closed-won), not the
-- rolled-out-units grain Parts A/B use. Deliberate -- a "celebration" is naturally
-- about a deal getting SIGNED, and funnel lag is inherently about the deal-creation
-- -> deal-closed relationship, neither of which exists on the property-grain table.
-- Same segment_bucket/team_bucket concept, recomputed here off STATIC_TEAM_NAME
-- (the new table's field) instead of HUBSPOT_STATIC_TEAM_NAME_DEAL -- same two-
-- taxonomy situation as everywhere else in this repo, not a new problem.
-- NO MSP FILTER on Parts C/D -- deal-grain MSP is the same dirty field
-- performance_cube.sql already dropped it for; don't reintroduce it here.
--
-- DSMB EXCLUSION ADDED 2026-07-31 -- Parts A/B/E already had the pmc_size join, but C/D didn't
-- -- caught in a repo-wide DSMB audit. These feed the AI narration directly (a "biggest deal"
-- or funnel-lag callout could be DSMB-driven). Same Pattern B pmc_size join as
-- performance_cube.sql, added to both parts below.
-- ================================================================================

-- Part C: biggest single deal in scope this period, AND what share of the scope's
-- total it represents -- this is what separates "worth celebrating" from "just a
-- number." A big deal that's 5% of the total is color; a big deal that's 60% of
-- the total IS the story (the segment isn't up, one deal is).
-- Validated live 2026-07-28, Strategic segment, this month: Connor Group Expansion,
-- 14,420 units, 13.4% of Strategic's total -- notable but not dominant. Compare to
-- Part B's Dana's-Team-by-rep example where one rep WAS ~60% -- different pattern,
-- and the summary should describe them differently, not with the same template.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT
        o.OPPORTUNITY_NAME, o.FLEX_UNIT_COUNT, o.CLOSED_AT_UTC,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN o.STATIC_TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            WHEN o.STATIC_TEAM_NAME IS NULL THEN 'Not Set'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED_WON AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND o.FLEX_UNIT_COUNT IS NOT NULL
      AND o.CLOSED_AT_UTC >= DATEADD(month, -1, CURRENT_DATE())
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      {{#Team.value}}     AND team_bucket = '{{Team.value}}'          {{/Team.value}}
      {{#Segment.value}}  AND segment_bucket = '{{Segment.value}}'   {{/Segment.value}}
      {{#DealType.value}} AND o.OPPORTUNITY_TYPE = '{{DealType.value}}' {{/DealType.value}}
)
SELECT
    OPPORTUNITY_NAME AS deal,
    FLEX_UNIT_COUNT AS units,
    CLOSED_AT_UTC AS closed_date,
    DIV0(FLEX_UNIT_COUNT, SUM(FLEX_UNIT_COUNT) OVER ()) AS share_of_scope_total
FROM scoped
ORDER BY FLEX_UNIT_COUNT DESC
LIMIT 3;

-- Part D: funnel lag -- was this period's closed-won number foreshadowed by pipeline
-- created last period, or does it contradict what the funnel predicted? Per Kevin:
-- "yes funnel lag is perfect." Uses BP-month as the lag unit (consistent with every
-- other period comparison in this repo) -- not a rigorously validated "30-45 day"
-- figure (unlike the 12-day close->rollout lag in units_closed_forecast_bridge.sql,
-- which WAS validated), so this is directional context, not a precise model.
-- Validated live 2026-07-28, company-wide: pipeline created ROSE 42% two periods ago
-- (1,496 -> 2,126 deals) and closed-won FOLLOWED with a rise last period (386,301 ->
-- 430,542 units) -- a real, visible lag relationship, not a coincidence.
WITH current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
bp_periods AS (
    SELECT 'this_month' AS period,
        DATEADD(day, 4, DATEADD(month, -1, bp_month_label)) AS start_date,
        LEAST(DATEADD(day, 3, bp_month_label), CURRENT_DATE()) AS end_date
    FROM current_bp
    UNION ALL
    SELECT 'last_month', DATEADD(day, 4, DATEADD(month, -2, bp_month_label)), DATEADD(day, 3, DATEADD(month, -1, bp_month_label)) FROM current_bp
    UNION ALL
    SELECT 'two_months_ago', DATEADD(day, 4, DATEADD(month, -3, bp_month_label)), DATEADD(day, 3, DATEADD(month, -2, bp_month_label)) FROM current_bp
),
pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT o.*,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN o.STATIC_TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            WHEN o.STATIC_TEAM_NAME IS NULL THEN 'Not Set'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      {{#Team.value}}     AND team_bucket = '{{Team.value}}'          {{/Team.value}}
      {{#Segment.value}}  AND segment_bucket = '{{Segment.value}}'   {{/Segment.value}}
      {{#DealType.value}} AND o.OPPORTUNITY_TYPE = '{{DealType.value}}' {{/DealType.value}}
)
SELECT
    p.period,
    COUNT(DISTINCT IFF(s.CREATED_AT_UTC BETWEEN p.start_date AND p.end_date, s.OPPORTUNITY_ID, NULL)) AS pipeline_created_deals,
    SUM(IFF(s.IS_CLOSED_WON AND s.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date, s.FLEX_UNIT_COUNT, 0)) AS closed_won_units
FROM bp_periods p
JOIN scoped s ON TRUE
GROUP BY 1
ORDER BY 1;

-- Part E: mix-trend persistence -- Expansion share, how many consecutive months has
-- it moved the SAME direction, and which direction right now. Per Kevin: "callouts
-- like our trend l6m is too much towards expansion etc, reorient the team towards
-- new logos" -- but only worth saying if it's an actual multi-month pattern, not a
-- 1-month blip. Validated live 2026-07-28, company-wide: current streak is length 1,
-- direction UP (Expansion share rose from 62% to 68% this month) -- following FOUR
-- months of net decline before that. This is a reversal, not a trend -- the summary
-- should say "reversed this month after declining most of this year," NOT "trending
-- toward expansion for months," which the raw single-month number alone would wrongly
-- imply if you only looked at the latest change.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT s.BP_MONTH, s.HUBSPOT_DEAL_TYPE, s.PROPERTY_UNIT_COUNT
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -8, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
      {{#Team.value}} AND s.HUBSPOT_STATIC_TEAM_NAME_DEAL = '{{Team.value}}' {{/Team.value}}
),
monthly AS (
    SELECT BP_MONTH, DIV0(SUM(IFF(HUBSPOT_DEAL_TYPE = 'Expansion', PROPERTY_UNIT_COUNT, 0)), SUM(PROPERTY_UNIT_COUNT)) AS expansion_share
    FROM base GROUP BY 1
),
with_change AS (
    SELECT BP_MONTH, expansion_share,
        SIGN(expansion_share - LAG(expansion_share) OVER (ORDER BY BP_MONTH)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (ORDER BY BP_MONTH) AS prev_sign
    FROM with_change
    WHERE chg_sign IS NOT NULL
),
with_group AS (
    SELECT *,
        SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (ORDER BY BP_MONTH) AS grp
    FROM with_lag
)
SELECT
    (SELECT expansion_share FROM monthly ORDER BY BP_MONTH DESC LIMIT 1) AS current_expansion_share,
    MAX(chg_sign) AS current_direction,
    COUNT(*) AS streak_length_months
FROM with_group
WHERE grp = (SELECT MAX(grp) FROM with_group);

-- Part F: activity leading indicator -- added 2026-07-29. Kevin, on what Sham actually needs
-- from this summary: "is our mix on new logo vs expansions trending poorly, or if activities
-- have dropped off drastically (bc this can forecast future unit drop offs)." Parts A-E cover
-- units/mix/deal-concentration but nothing about calls/meetings -- this closes that gap.
-- Calls/meetings, this vs last month, same team_bucket-eligible-rep scope as
-- activity_vs_outcome_by_rep.sql (deduped, grace-period-aware, PARENT_TEAM-guarded) so a
-- departed/mis-tagged rep can't distort the trend the summary reports on.
-- Validated live 2026-07-29, company-wide: calls UP 7.7% (34,849 -> 37,542) but meetings DOWN
-- 9.7% (1,103 -> 996) -- a genuinely mixed signal, not a single clean direction. The LLM
-- narration layer should say exactly that (mixed, not "activity is down") -- don't let either
-- number alone drive the headline if they disagree.
WITH current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
bp_periods AS (
    SELECT 'this_month' AS period, DATEADD(day, 4, DATEADD(month, -1, bp_month_label)) AS start_date,
        LEAST(DATEADD(day, 3, bp_month_label), CURRENT_DATE()) AS end_date FROM current_bp
    UNION ALL
    SELECT 'last_month_full', DATEADD(day, 4, DATEADD(month, -2, bp_month_label)),
        DATEADD(day, 3, DATEADD(month, -1, bp_month_label)) FROM current_bp
),
emp_dedup AS (
    SELECT EMPLOYEE_SK, EMAIL FROM FLEX.MART.DIM_EMPLOYEE_HISTORY
    WHERE SOURCE_SYSTEM = 'salesforce' AND IS_CURRENT = TRUE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY UPDATED_AT_UTC DESC) = 1
),
user_dedup AS (
    SELECT EMAIL, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMAIL ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
team_map AS (
    SELECT ed.EMPLOYEE_SK,
        CASE
            WHEN u.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN u.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND u.PARENT_TEAM = 'Mid Market +' THEN 'Strategic'
            WHEN u.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN u.TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket
    FROM emp_dedup ed JOIN user_dedup u ON ed.EMAIL = u.EMAIL
    WHERE u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE())
),
calls AS (
    SELECT p.period, COUNT(DISTINCT t.TASK_ID) AS calls
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_TASK t ON t.COMPLETED_AT_UTC BETWEEN p.start_date AND p.end_date
        AND t.TASK_STATUS = 'completed' AND t.TASK_TYPE = 'call'
    JOIN team_map tm ON t.EMPLOYEE_SK = tm.EMPLOYEE_SK AND tm.segment_bucket IS NOT NULL
        {{#Segment.value}} AND tm.segment_bucket = '{{Segment.value}}' {{/Segment.value}}
    GROUP BY 1
),
meetings AS (
    SELECT p.period, COUNT(DISTINCT m.MEETING_ID) AS meetings
    FROM bp_periods p
    JOIN FLEX.SALES.FCT_CRM_MEETING m ON m.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date
        AND m.MEETING_STATUS = 'completed'
    JOIN team_map tm ON m.EMPLOYEE_SK = tm.EMPLOYEE_SK AND tm.segment_bucket IS NOT NULL
        {{#Segment.value}} AND tm.segment_bucket = '{{Segment.value}}' {{/Segment.value}}
    GROUP BY 1
)
SELECT COALESCE(c.period, mt.period) AS period, c.calls, mt.meetings
FROM calls c
FULL OUTER JOIN meetings mt ON c.period = mt.period
ORDER BY 1;
