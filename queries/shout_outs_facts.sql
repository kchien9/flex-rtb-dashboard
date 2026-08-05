-- Shout Outs / Celebrations, Facts -- Kevin: "some ai generated call outs for high
-- performance... maybe actually do one message - and call out 1 person per team. Then sham
-- can copy paste and drop into our org slack thread." Same architecture as
-- ai_summary_facts.sql: this query only gathers facts, a downstream LLM call narrates them
-- into ONE Slack-ready message (one line per team, 4 lines total) -- never the other way
-- around, never let the LLM invent a number.
--
-- NON-NEGOTIABLE FRAMING RULE, straight from Kevin: "do not ever shout out one person by
-- putting down another. only focus on positive framing." Every fact below is either (a)
-- purely self-referential (a rep's own personal best, no comparison to teammates at all) or
-- (b) a positive fact ABOUT the featured person (led the team, closed N deals) that never
-- needs to name or reference anyone else to be true. The LLM system prompt consuming this
-- output must be told explicitly: describe what the featured person achieved, never mention,
-- imply, or rank against a teammate's performance (no "beat everyone," no "unlike last month's
-- leader," no comparative language at all) -- this is a presentation-layer instruction, this
-- query just needs to supply facts that are safe to phrase that way.
--
-- THREE FACT TYPES PER REP, let the LLM pick the best story per team -- not pre-selected here,
-- because "which achievement is most worth celebrating" is a judgment call, not something to
-- hard-code:
--   1. leader_streak_months -- consecutive months (ending THIS month) this rep has had the
--      most rolled-out units on their own team. 0 if they aren't this month's leader at all.
--      Validated live: real streaks exist but are usually short (1-2 months) -- don't expect
--      an "N straight months" story every period, most months the best available fact will be
--      #2 or #3 below.
--   2. is_personal_best -- this month's rolled-out units are higher than any of their own
--      trailing 5 months. Purely self-referential, zero comparison to teammates -- the safest
--      fact type given the framing rule above. IMPORTANT SCOPE NOTE (clarified 2026-08-05, per
--      Kevin's "are you sure about the personal bests? how do u know"): this is a "best of the
--      trailing 6 months" claim, NOT a literal career-best -- there's no lifetime lookback here.
--      Verified live against 4 real featured reps (Cory Baach, Umar Khan, Caleb Benson, Brianne
--      Santa-Donato): all 4 claims were arithmetically correct (this month was the max of their
--      own 6-month window). One nuance worth knowing, not a bug: a rep can satisfy the
--      `prior_month_count >= 2` guard with EXACTLY 2 prior months (a newer rep who just started
--      ramping) -- their claim is still true, but rests on a thinner comparison base than a rep
--      with a full 6-month history. Don't relabel this as "career best" in narration without
--      building a real lifetime lookback first.
--   3. new_logo_deals_this_month -- real, simple, positive count, via FCT_CRM_OPPORTUNITY
--      OWNER_SK (current identity), Closed Won, New Logo only. Validated live: real range is
--      0-13 deals this month across reps -- meaningfully different between people, a genuine
--      volume signal, not a rounding artifact.
--
-- SELECTION GUIDANCE FOR THE LLM PROMPT (not enforced in SQL, since "most compelling" is
-- inherently a narrative judgment): prefer the fact with the most concrete, specific number
-- (a 3-month streak beats a 1-month streak; a personal best is more specific than a generic
-- "had a good month"). If a team has no rep with ANY notable fact this period (rare but
-- possible), it's fine for that team to be skipped in the final message rather than forcing a
-- callout that doesn't exist -- per Kevin's own "only positive framing" rule, an empty team is
-- better than the LLM manufacturing a reason to feature someone.
--
-- Team membership resolved from CURRENT STG_SALESFORCE__USER.TEAM_NAME (same fix applied
-- everywhere else in this repo 2026-07-30 -- see rep_leaderboard.sql's header) -- a manager
-- like Rory Averett correctly never appears here as a candidate to shout out.

WITH user_dedup AS (
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
pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT s.BP_MONTH, s.HUBSPOT_DEAL_OWNER AS rep, cr.team_bucket,
        SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)) AS units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    JOIN current_rep cr ON cr.FULL_NAME = s.HUBSPOT_DEAL_OWNER AND cr.team_bucket IS NOT NULL
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND (cr.IS_ACTIVE OR cr.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
      AND s.BP_MONTH >= DATEADD(month, -6, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2, 3
),
ranked AS (
    SELECT *,
        IFF(RANK() OVER (PARTITION BY team_bucket, BP_MONTH ORDER BY units DESC) = 1, 1, 0) AS is_leader
    FROM monthly
),
streaks AS (
    SELECT *,
        SUM(IFF(is_leader = 0, 1, 0)) OVER (PARTITION BY team_bucket, rep ORDER BY BP_MONTH) AS break_grp
    FROM ranked
),
leader_streak AS (
    SELECT team_bucket, rep, BP_MONTH,
        COUNT(*) OVER (PARTITION BY team_bucket, rep, break_grp ORDER BY BP_MONTH) AS streak_len
    FROM streaks
    WHERE is_leader = 1 AND BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
),
personal_best AS (
    -- BUG CAUGHT VALIDATING LIVE (#1): an earlier draft computed prior_max_units with a window
    -- function AFTER already filtering `monthly` down to only the current BP month -- so
    -- "BP_MONTH < current_max" was false for every remaining row, prior_max_units was always
    -- NULL, COALESCE(NULL,-1) made the comparison trivially true, and EVERY rep (including
    -- reps with 0 units) came back is_personal_best=TRUE. Fixed by aggregating across all 6
    -- months in one GROUP BY, before any filtering to "this month."
    --
    -- BUG CAUGHT VALIDATING LIVE (#2), per Kevin's own catch: a rep with only ONE month of
    -- history EVER (a true new hire, e.g. Demri Williams/Shane Bierfeldt -- confirmed live,
    -- both show a single BP_MONTH row total across the full 6-month lookback) had
    -- prior_max_units = NULL -> COALESCE to -1 -> ANY positive number this month trivially
    -- counted as a "personal best." That's not a real personal best, it's their only data
    -- point -- calling it out would overstate a first month as an achievement. Fixed by
    -- requiring at least 2 PRIOR months of real (non-null) history before the claim can be
    -- TRUE (see prior_month_count below, used in the final SELECT's is_personal_best).
    --
    -- Note this is a *tenure* guard (does the rep have enough of their own history to make
    -- "best" meaningful), separate from the *team-scoping* question Kevin also raised (should
    -- a rep who moved from Brandon's to Dana's team have their pre-move months counted at
    -- all) -- team_bucket here is resolved once per PERSON from current status (see
    -- current_rep above), so a mover's full name-matched history already counts toward their
    -- own personal best regardless of which team a given month's deals were nominally tagged
    -- under -- that's deliberate, consistent with this repo's person-not-deal team rule.
    SELECT team_bucket, rep,
        MAX(IFF(BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) AS this_month_units,
        MAX(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), units, NULL)) AS prior_max_units,
        COUNT(IFF(BP_MONTH < (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS), 1, NULL)) AS prior_month_count
    FROM monthly
    GROUP BY team_bucket, rep
),
new_logo AS (
    SELECT cr.team_bucket, e.FULL_NAME AS rep,
        COUNT(DISTINCT o.OPPORTUNITY_ID) AS new_logo_deals_this_month
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE AND e.SOURCE_SYSTEM = 'salesforce'
    JOIN current_rep cr ON cr.FULL_NAME = e.FULL_NAME AND cr.team_bucket IS NOT NULL
    WHERE o.IS_CLOSED_WON AND o.OPPORTUNITY_TYPE = 'New Logo'
      AND o.CLOSED_AT_UTC >= DATEADD(day, 4, DATEADD(month, -1, DATE_TRUNC('month', CURRENT_DATE())))
    GROUP BY 1, 2
)
SELECT
    COALESCE(pb.team_bucket, ls.team_bucket, nl.team_bucket) AS team,
    COALESCE(pb.rep, ls.rep, nl.rep)                          AS rep,
    COALESCE(ls.streak_len, 0)                                AS leader_streak_months,
    -- Guard against a 0-unit "personal best," AND against a true new hire's first month
    -- trivially counting as one (prior_month_count >= 2 required -- see personal_best CTE).
    IFF(pb.this_month_units > 0 AND pb.prior_month_count >= 2 AND pb.this_month_units > pb.prior_max_units, TRUE, FALSE) AS is_personal_best,
    pb.this_month_units,
    COALESCE(nl.new_logo_deals_this_month, 0)                 AS new_logo_deals_this_month
FROM personal_best pb
FULL OUTER JOIN leader_streak ls ON pb.team_bucket = ls.team_bucket AND pb.rep = ls.rep
FULL OUTER JOIN new_logo nl ON COALESCE(pb.team_bucket, ls.team_bucket) = nl.team_bucket AND COALESCE(pb.rep, ls.rep) = nl.rep
WHERE COALESCE(ls.streak_len, 0) > 0
   OR IFF(pb.this_month_units > 0 AND pb.prior_month_count >= 2 AND pb.this_month_units > pb.prior_max_units, TRUE, FALSE)
   OR COALESCE(nl.new_logo_deals_this_month, 0) >= 3
ORDER BY team, leader_streak_months DESC, new_logo_deals_this_month DESC;
