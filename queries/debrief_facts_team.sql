-- Debrief Facts, by Team -- the "individual drivers" layer for the Debrief tab when a manager
-- pod is the selected dimension. Per Kevin: "if he wants to understand how rory's team is
-- doing he can select rory team, this quarter, and it will give insights, trends, concerning
-- things on rory's aggregate team performance AND THE INDIVIDUAL DRIVERS." The team-level
-- headline (aggregate this-vs-last, top drivers, funnel lag, mix trend) already exists and is
-- already {{ Team.value }}-filterable via ai_summary_facts.sql -- that stays the headline
-- source. This file is the one real gap: ONE per-rep row combining unit trend, win rate, and
-- notable-achievement facts, so the LLM narrates from a single coherent fact set instead of
-- stitching team_rep_units_trend.sql + closed_lost_analysis.sql Part C + shout_outs_facts.sql
-- together itself.
--
-- Requires {{ Team.value }} to be set (one of Brandon's/Rory's/Sebastian's/Dana's Team) -- same
-- scoping as team_rep_units_trend.sql, not meant to run unfiltered.
--
-- REUSES ALREADY-VALIDATED LOGIC, NOT RE-DERIVED:
--   - Unit trend basis: same person-not-deal team resolution as team_rep_units_trend.sql /
--     rep_leaderboard.sql (current STG_SALESFORCE__USER.TEAM_NAME, not a historical deal tag).
--   - Win rate: same OWNER_SK-resolved rep + win/loss definition as closed_lost_analysis.sql
--     Part C.
--   - leader_streak_months / is_personal_best: same rank-via-gaps-and-islands and 2-prior-month
--     guard as shout_outs_facts.sql (that guard exists because a true new hire's first month
--     was trivially counting as a "personal best" with zero prior history -- see that file's
--     header for the live bug this fixed).
--   - DSMB excluded via the standard pmc_size join on both the units side (Pattern A) and the
--     deal side (Pattern B), matching the repo-wide DSMB audit completed 2026-07-31.
--
-- SCOPE, DELIBERATELY -- this file does NOT compute a team-level total. That's
-- ai_summary_facts.sql's job (already Team-filterable) -- duplicating it here would give the
-- LLM two different team totals to reconcile. This file is rep rows only.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
user_dedup AS (
    SELECT FULL_NAME, TEAM_NAME, PARENT_TEAM, IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
),
current_rep AS (
    SELECT FULL_NAME,
        CASE
            WHEN TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') AND PARENT_TEAM = 'Mid Market +' THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        IS_ACTIVE, LAST_LOGIN_AT_UTC
    FROM user_dedup
),
monthly AS (
    SELECT s.BP_MONTH, s.HUBSPOT_DEAL_OWNER AS rep,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    JOIN current_rep cr ON cr.FULL_NAME = s.HUBSPOT_DEAL_OWNER AND cr.team_bucket = '{{ Team.value }}'
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND (cr.IS_ACTIVE OR cr.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
      AND s.BP_MONTH >= DATEADD(month, -6, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
),
ranked AS (
    SELECT *, IFF(RANK() OVER (PARTITION BY BP_MONTH ORDER BY units DESC) = 1, 1, 0) AS is_leader
    FROM monthly
),
streaks AS (
    SELECT *, SUM(IFF(is_leader = 0, 1, 0)) OVER (PARTITION BY rep ORDER BY BP_MONTH) AS break_grp
    FROM ranked
),
leader_streak AS (
    SELECT rep, COUNT(*) OVER (PARTITION BY rep, break_grp ORDER BY BP_MONTH) AS streak_len
    FROM streaks
    WHERE is_leader = 1 AND BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
),
unit_facts AS (
    SELECT rep,
        MAX(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) AS units_this,
        MAX(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)), units, NULL)) AS units_last,
        MAX(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) AS prior_max_units,
        COUNT(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), 1, NULL)) AS prior_month_count
    FROM monthly
    GROUP BY rep
),
win_rate AS (
    SELECT e.FULL_NAME AS rep,
        COUNT(*) AS total_closed_deals,
        SUM(IFF(o.IS_CLOSED_WON, 1, 0)) AS won_deals,
        DIV0(SUM(IFF(o.IS_CLOSED_WON, 1, 0)), COUNT(*)) AS win_rate_by_deals,
        DIV0(SUM(IFF(o.IS_CLOSED_WON, o.FLEX_UNIT_COUNT, 0)), SUM(IFF(o.FLEX_UNIT_COUNT IS NOT NULL, o.FLEX_UNIT_COUNT, 0))) AS win_rate_by_units,
        SUM(IFF(o.IS_CLOSED_WON AND o.OPPORTUNITY_TYPE = 'New Logo'
                AND o.CLOSED_AT_UTC >= DATEADD(day, 4, DATEADD(month, -1, DATE_TRUNC('month', CURRENT_DATE()))), 1, 0)) AS new_logo_deals_this_month
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE AND e.SOURCE_SYSTEM = 'salesforce'
    JOIN current_rep cr ON cr.FULL_NAME = e.FULL_NAME AND cr.team_bucket = '{{ Team.value }}'
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND o.CLOSED_AT_UTC >= DATEADD(month, -6, CURRENT_DATE())
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
    GROUP BY 1
)
SELECT
    COALESCE(uf.rep, wr.rep)                                          AS rep,
    uf.units_this,
    uf.units_last,
    uf.units_this - uf.units_last                                     AS units_change,
    COALESCE(ls.streak_len, 0)                                        AS leader_streak_months,
    IFF(uf.units_this > 0 AND uf.prior_month_count >= 2 AND uf.units_this > uf.prior_max_units, TRUE, FALSE) AS is_personal_best,
    wr.total_closed_deals,
    wr.win_rate_by_deals,
    wr.win_rate_by_units,
    COALESCE(wr.new_logo_deals_this_month, 0)                         AS new_logo_deals_this_month
FROM unit_facts uf
FULL OUTER JOIN win_rate wr ON uf.rep = wr.rep
LEFT JOIN leader_streak ls ON COALESCE(uf.rep, wr.rep) = ls.rep
ORDER BY uf.units_this DESC NULLS LAST;
