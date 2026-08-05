-- Closed Lost Analysis -- Kevin: "i like closed lost analysis - we can show reasons and also
-- trends on closed lost. if our win rate is going down he would want to know. but each segment
-- gets its own win rate." Two parts: WHY we lose (reasons, categorized), and IS win rate
-- moving (by segment, trended, both by deal count and by units).
--
-- REAL LOSS vs. ADMINISTRATIVE CLEANUP -- CLOSED_LOST_REASON has 27 distinct values, and they
-- are NOT all the same kind of fact. "Went with competitor," "Went With Embed Option Instead
-- of DI," "Legal concerns," "Refusal to Sign FSA" are real sales-execution/competitive losses
-- -- exactly what a VP should know about. "Auto Close - Inactivity," "Auto Close - Pipeline
-- Cleanup," "Duplicate Opportunity," "Duplicate Account," "Stale Deal/Migration" are data-
-- hygiene housekeeping, not a sales loss at all -- an opportunity that was never really live
-- getting closed out isn't the same event as a customer choosing a competitor. Same principle
-- already applied to the AI summary (see docs/superblocks-setup.md's AI Summary section --
-- "never let a data-hygiene artifact read as a business signal"). `is_administrative` tags
-- this explicitly so the UI can filter/group them separately rather than blending "we lost to
-- a competitor" and "this was a duplicate record" into one undifferentiated bar.
--
-- WIN RATE, BOTH WAYS, DELIBERATELY -- checked live: count-based win rate is smooth and
-- unremarkable (80-95% every month, every segment). Unit-weighted win rate is dramatically
-- more volatile -- Strategic swung from 88% to 26% to 95% in consecutive months, MM/Ent from
-- 21% to 76% to 42%. This dashboard is about units, not deal counts (established principle
-- throughout this repo), so unit-weighted is the primary number -- but a single large lost
-- (or won) deal can swing it hard, which is exactly why `deals` and `units` are both shown:
-- a 26%-by-units month driven by one 240K-unit loss reads very differently from the same
-- number spread across 20 deals. Don't report the unit win rate without the deal count next
-- to it.
--
-- CURRENT/PARTIAL BP MONTH EXCLUDED FROM THE TREND -- the most recent 1-2 months in the lookback
-- window can have single-digit deal counts (the BP month just started) -- checked live,
-- 2026-08 showed 0 won / a handful lost purely because almost nothing has closed yet this
-- period, not because win rate collapsed. Only fully-elapsed BP months are included below
-- (same censoring-bias principle as insights_stage_velocity.sql's Part A).
--
-- Scoped to New Logo/Expansion/Move In (matches performance_cube.sql's deal-type scope) and
-- FLEX_UNIT_COUNT IS NOT NULL (a handful of closed deals have no unit count at all -- excluded
-- from the units view, not zero-filled, so they don't silently understate lost units).
--
-- REASON DRILL-DOWN NOW DIMENSION-FILTERABLE (added 2026-08-04) -- Part A used to accept only
-- `{{ Segment.value }}`. Extended to also accept `{{ Team.value }}` / `{{ Msp.value }}` /
-- `{{ DealType.value }}` / `{{ Rep.value }}` (same filter set as the new
-- closed_lost_rate_cube.sql), so the reason
-- breakdown can be pulled for one SPECIFIC flagged slice -- Kevin: "sham can be like huh we're
-- losing a lot of x msp deals - why?" A rep filter requires resolving OWNER_SK ->
-- DIM_EMPLOYEE_HISTORY.FULL_NAME (same real per-record resolution Part C already uses), so
-- that join is now always present in `reasons`, not added only for Part C.
--
-- BUG FIXED 2026-08-04 -- Part B's "fully-elapsed months only" gate compared a calendar-month
-- bucket against a BP-month LABEL (mixing two different calendars) -- caught building
-- closed_lost_rate_cube.sql/insights_closed_lost_streak.sql, where the exact same construction
-- produced a false, dramatic "loss rate spike" concentrated entirely in one barely-started
-- calendar month (confirmed live 2026-08-05: the BP label had already flipped to Sep BP while
-- August was only 5 of 31 days old). Fixed here too, to a pure calendar check with no BP-label
-- mixing: `DATE_TRUNC('month', CLOSED_AT_UTC) < DATE_TRUNC('month', CURRENT_DATE())`.

-- Part A: loss reasons, trailing {{ LookbackMonths.value }} months (default 6), this vs. an
-- equal-length prior window, categorized.
--
-- DSMB EXCLUSION ADDED 2026-07-31 (all 3 parts) -- none of them had any account-size filter,
-- caught in a repo-wide DSMB audit per Kevin's explicit ask. Same Pattern B pmc_size join as
-- performance_cube.sql (via DIM_CRM_ACCOUNT_HISTORY.PMC_ID).
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
reasons AS (
    SELECT
        o.CLOSED_LOST_REASON,
        CASE
            WHEN o.CLOSED_LOST_REASON IN (
                'Auto Close - Inactivity', 'Auto Close - Pipeline Cleanup', 'Duplicate Opportunity',
                'Duplicate Account', 'Stale Deal/Migration'
            ) THEN TRUE
            ELSE FALSE
        END AS is_administrative,
        o.FLEX_UNIT_COUNT,
        IFF(o.CLOSED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, CURRENT_DATE()), 'current_window', 'prior_window') AS window
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE AND e.SOURCE_SYSTEM = 'salesforce'
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED AND NOT o.IS_CLOSED_WON AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND o.CLOSED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }} * 2, CURRENT_DATE())
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      {{#Segment.value}} AND CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            ELSE NULL
        END = '{{Segment.value}}' {{/Segment.value}}
      {{#Team.value}}      AND CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END = '{{Team.value}}'                                                                    {{/Team.value}}
      {{#Msp.value}}       AND COALESCE(o.PARTNER_MANAGEMENT_SOFTWARE, 'Not Set') = '{{Msp.value}}' {{/Msp.value}}
      {{#DealType.value}}  AND o.OPPORTUNITY_TYPE = '{{DealType.value}}'                            {{/DealType.value}}
      {{#Rep.value}}        AND e.FULL_NAME = '{{Rep.value}}'                                        {{/Rep.value}}
)
SELECT
    COALESCE(CLOSED_LOST_REASON, 'Not Specified') AS reason,
    is_administrative,
    SUM(IFF(window = 'current_window', 1, 0))                        AS deals_this_window,
    SUM(IFF(window = 'current_window', FLEX_UNIT_COUNT, 0))          AS units_this_window,
    SUM(IFF(window = 'prior_window', 1, 0))                          AS deals_prior_window,
    SUM(IFF(window = 'prior_window', FLEX_UNIT_COUNT, 0))            AS units_prior_window
FROM reasons
GROUP BY 1, 2
ORDER BY units_this_window DESC;

-- Part B: win rate by segment, monthly, fully-elapsed BP months only.
WITH pmc_size AS (
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
            ELSE NULL
        END AS segment_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND o.CLOSED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, DATE_TRUNC('month', CURRENT_DATE()))
      -- fully-elapsed calendar months only, pure calendar check -- see header bug note
      AND DATE_TRUNC('month', o.CLOSED_AT_UTC) < DATE_TRUNC('month', CURRENT_DATE())
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      {{#Segment.value}} AND CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            ELSE NULL
        END = '{{Segment.value}}' {{/Segment.value}}
)
SELECT
    segment_bucket,
    DATE_TRUNC('month', CLOSED_AT_UTC)                                          AS closed_month,
    COUNT(*)                                                                     AS total_closed_deals,
    SUM(IFF(IS_CLOSED_WON, 1, 0))                                                AS won_deals,
    DIV0(SUM(IFF(IS_CLOSED_WON, 1, 0)), COUNT(*))                                AS win_rate_by_deals,
    SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0))                    AS total_closed_units,
    SUM(IFF(IS_CLOSED_WON, FLEX_UNIT_COUNT, 0))                                  AS won_units,
    DIV0(SUM(IFF(IS_CLOSED_WON, FLEX_UNIT_COUNT, 0)), SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0))) AS win_rate_by_units
FROM scoped
WHERE segment_bucket IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, 2;

-- Part C: win rate by REP -- Kevin (2026-07-30): "conversion rate... rep level i think... of
-- all open opportunities theyre owner of how many closed won" -- interpreted as the same win-
-- rate definition as Part B (won / (won + lost), by deal count AND by units, same reasoning on
-- why both), just re-grouped by owner instead of segment. If a straight win/loss rate isn't
-- what was meant, flag it and this gets adjusted -- there wasn't a second obvious reading of
-- "how many closed won" that wasn't just this.
--
-- REP RESOLVED VIA OWNER_SK, NOT A DEAL-LEVEL TEAM TAG -- this is "who owned THIS closed deal,"
-- a real per-record fact (unlike STATIC_TEAM_NAME's known bulk-attribution artifacts on OPEN
-- deals -- see pipeline_by_stage.sql's header) -- same resolution closed_won_by_rep.sql already
-- uses and this repo confirmed correct.
--
-- DEPARTURE GRACE PERIOD APPLIED -- Kevin's standing rule: "i dont want to see inactive or
-- users on entirely diff teams in any table." DIM_EMPLOYEE_HISTORY (used to resolve OWNER_SK ->
-- a name) has no IS_ACTIVE/LAST_LOGIN_AT_UTC of its own, so team_bucket AND the grace-period
-- check are resolved from STG_SALESFORCE__USER by FULL_NAME, same canonical pattern as
-- rep_leaderboard.sql/team_rep_units_trend.sql -- not a second, inconsistent method.
--
-- No monthly trend here (unlike Part B's segment trend) -- at rep grain, a single BP month's
-- closed-deal count per person is often in the single digits, which is exactly the small-
-- sample noise this repo already flagged and excluded for the current partial month in Part B
-- -- one trailing-window total per rep is the stable, meaningful number at this grain.
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
rep_scoped AS (
    SELECT o.*, e.FULL_NAME AS rep, cr.team_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE AND e.SOURCE_SYSTEM = 'salesforce'
    JOIN current_rep cr ON cr.FULL_NAME = e.FULL_NAME AND cr.team_bucket IS NOT NULL
    LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
    LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
    WHERE o.IS_CLOSED AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      AND o.CLOSED_AT_UTC >= DATEADD(month, -{{ LookbackMonths.value }}, CURRENT_DATE())
      AND (cr.IS_ACTIVE OR cr.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
      AND (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
      {{#Team.value}} AND cr.team_bucket = '{{Team.value}}' {{/Team.value}}
)
SELECT
    rep,
    team_bucket,
    COUNT(*)                                                                     AS total_closed_deals,
    SUM(IFF(IS_CLOSED_WON, 1, 0))                                                AS won_deals,
    DIV0(SUM(IFF(IS_CLOSED_WON, 1, 0)), COUNT(*))                                AS win_rate_by_deals,
    SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0))                    AS total_closed_units,
    SUM(IFF(IS_CLOSED_WON, FLEX_UNIT_COUNT, 0))                                  AS won_units,
    DIV0(SUM(IFF(IS_CLOSED_WON, FLEX_UNIT_COUNT, 0)), SUM(IFF(FLEX_UNIT_COUNT IS NOT NULL, FLEX_UNIT_COUNT, 0))) AS win_rate_by_units
FROM rep_scoped
GROUP BY 1, 2
HAVING total_closed_deals > 0
ORDER BY win_rate_by_units DESC;
