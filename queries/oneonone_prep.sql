-- 1:1 Prep -- structures Sham's 1:1s with his 5 direct reports (Brandon, Dana, Rory,
-- Sebastian, Hans): a team-level trend ("Rory, your team did 50% less units this month vs
-- last -- what's going on?") plus enough context to know WHY before the conversation starts,
-- including whether the swing is headcount-driven (someone left/moved) vs. a real
-- performance dip among people still on the team. Big picture first -- per Kevin, individual
-- rep detail is secondary, this is about giving Sham something concrete per manager, not a
-- roster browser.
--
-- REBUILT 2026-07-27 -- first draft hardcoded a hand-typed roster (from Rippling's
-- reporting_to field) as a VALUES CTE. Wrong call: that roster was stale the moment it was
-- written (missing two of Rory's real reports -- Anttarch "AJ" Brandy wasn't in it at all --
-- and didn't reflect Ruby Baer's recent move to Brandon's team). Comp rosters update on a
-- payroll cadence, not in real time, and hardcoding a snapshot just re-creates the same
-- staleness on a delay.
--
-- FIX: don't track individual rosters at all. HUBSPOT_STATIC_TEAM_NAME_DEAL already carries
-- a pod-level label (personalized for some managers -- "Brandon's Team" -- generic for
-- others -- "SMB Account Executives 1/2") that IS the team grouping key, no roster needed.
-- Confirmed with Kevin: SMB Account Executives 1 = Sebastian Bohlmann's pod, SMB Account
-- Executives 2 = Rory Averett's pod. Dana Finch = "Heidi's Team" (stale label -- Heidi has
-- left, Dana runs it now, confirmed 2026-07-28). Hans's pod name still needs confirming
-- (Hans manages SDRs -- activity-side tables, not this units-side query, separately).
--
-- DEPARTURE / REASSIGNMENT DETECTION -- the actual reason this matters: a team's number can
-- drop because someone left, not because the remaining team underperformed, and those need
-- different framing in a 1:1. Cross-referencing each historically-contributing rep against
-- FLEX.STG_SALESFORCE.STG_SALESFORCE__USER's live IS_ACTIVE + TEAM_NAME (not the stale
-- Rippling snapshot) distinguishes "still on the team, trending down" from "no longer here."
-- Validated live 2026-07-27 on Rory's pod: Redding Tews and Jacob Fidler show
-- IS_ACTIVE = FALSE (departed); Zach Branson now shows TEAM_NAME = Sebastian's pod, not
-- Rory's (reassigned). Both would otherwise look like unexplained performance drops.
--
-- FILTER ESCAPING -- same apostrophe risk as every value filter in this repo.
--
-- DEDUP FIX (2026-07-29) -- confirmed elsewhere in this repo that STG_SALESFORCE__USER can
-- carry duplicate rows per FULL_NAME (Morgan Giles, Brad Robins -- one real/active, one stale/
-- deactivated with a mangled username). Part B's join on FULL_NAME was naive and could
-- non-deterministically pick either one -- deduped via the same QUALIFY pattern as
-- rep_leaderboard.sql. NOT applying the grace-period exclusion here on purpose -- this file's
-- entire point is to SHOW departed/reassigned status as 1:1 context, not hide it.

-- Part A: team-level trend, per manager's pod -- the headline number for the 1:1
SELECT
    '{{ PodName.value }}'                                                AS pod,
    SUM(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
            AND IS_INTEGRATED_TOTAL, PROPERTY_UNIT_COUNT, 0))            AS units_this,
    SUM(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
            AND IS_INTEGRATED_TOTAL, PROPERTY_UNIT_COUNT, 0))            AS units_last
FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
WHERE HUBSPOT_STATIC_TEAM_NAME_DEAL = '{{ PodName.value }}';

-- Part B: per-rep breakdown within the pod, classified current vs. departed/reassigned --
-- the "why" behind Part A's number, and specifically what to flag as headcount context
-- rather than a performance concern.
WITH user_dedup AS (
    SELECT FULL_NAME, TEAM_NAME, IS_ACTIVE
    FROM FLEX.STG_SALESFORCE.STG_SALESFORCE__USER
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FULL_NAME ORDER BY IS_ACTIVE DESC, LAST_LOGIN_AT_UTC DESC) = 1
)
SELECT
    r.rep,
    r.units_this,
    r.units_last,
    r.units_this - r.units_last                                          AS change,
    u.TEAM_NAME                                                           AS current_team,
    u.IS_ACTIVE                                                           AS currently_active,
    CASE
        WHEN u.IS_ACTIVE = FALSE THEN 'departed'
        WHEN u.TEAM_NAME IS DISTINCT FROM '{{ PodName.value }}' THEN 'reassigned to ' || COALESCE(u.TEAM_NAME, 'unknown team')
        ELSE 'still on team'
    END                                                                   AS status
FROM (
    SELECT HUBSPOT_DEAL_OWNER AS rep,
        SUM(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
                AND IS_INTEGRATED_TOTAL, PROPERTY_UNIT_COUNT, 0))         AS units_this,
        SUM(IFF(BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
                AND IS_INTEGRATED_TOTAL, PROPERTY_UNIT_COUNT, 0))         AS units_last
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE HUBSPOT_STATIC_TEAM_NAME_DEAL = '{{ PodName.value }}'
    GROUP BY 1
    HAVING units_this > 0 OR units_last > 0
) r
LEFT JOIN user_dedup u ON u.FULL_NAME = r.rep
ORDER BY r.units_this - r.units_last ASC;

-- Pod name reference (confirmed with Kevin 2026-07-27, Dana resolved 2026-07-28, Hans still open):
--   Brandon Nicastro -> HUBSPOT_STATIC_TEAM_NAME_DEAL = "Brandon's Team"
--   Rory Averett     -> HUBSPOT_STATIC_TEAM_NAME_DEAL = "SMB Account Executives 2"
--   Sebastian Bohlmann -> HUBSPOT_STATIC_TEAM_NAME_DEAL = "SMB Account Executives 1"
--   Dana Finch       -> HUBSPOT_STATIC_TEAM_NAME_DEAL = "Heidi's Team" -- STALE POD LABEL:
--     Heidi (the prior manager) has left the company; Dana runs this pod now. The field
--     itself still says "Heidi's Team" -- don't expect it to say "Dana's Team," it won't.
--   Hans Bredahl     -> SDR org, needs FCT_CRM_TASK/FCT_CRM_MEETING (activity), not this
--     units-side query at all
