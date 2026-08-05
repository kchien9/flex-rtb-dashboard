-- Rolled-Out Units Cube — recap vs. new, MSP, segment, team, deal type, by month
-- Feeds the monthly lookback page. STAYS ON OLD TABLE — no new-platform (FLEX.*) equivalent
-- exists yet for the rollout/recap/tier/MSP/segment flags. See docs/replatform-notes.md.
--
-- {{ Dimension.value }} is a Superblocks dropdown bound to a column name, so one query
-- drives every slice (PMS / HUBSPOT_DEAL_TYPE / segment_bucket / team_bucket /
-- HUBSPOT_DEAL_OWNER). Constrain this dropdown's options to exactly those 5 values in
-- Superblocks -- it's a raw SQL identifier substitution, not a value, so it can't be
-- parameterized like the filters below. Never let it be free text.
-- NOTE: segment_bucket replaced HUBSPOT_COMPANY_SEGMENT, and team_bucket replaced
-- HUBSPOT_STATIC_TEAM_NAME_DEAL, both 2026-07-28 -- the raw fields are known-unreliable/dirty
-- (see README's data quality gotchas) -- segment_bucket and team_bucket are the validated
-- mappings defined below.
--
-- FILTER ESCAPING -- READ BEFORE WIRING: real team names contain apostrophes
-- ("Brandon's Team", "Cory's Team") which BREAK naive '{{Value}}' string interpolation --
-- confirmed live: `... = 'Brandon's Team'` is a SQL syntax error, not a hypothetical.
-- Prefer Superblocks' native bind-parameter syntax for the Snowflake connector (properly
-- escaped by the driver) over raw Mustache string substitution for every value filter below.
-- MULTI-SELECT, added 2026-08-05 -- all 5 filters below are now `IN ({{X.value}})`, not
-- `= '{{X.value}}'`. The QUOTES are no longer supplied by this file -- {{X.value}} must render
-- as an already-quoted, comma-separated list (e.g. Team.value -> 'Brandon''s Team' for one
-- selection, 'Brandon''s Team','Dana''s Team' for two), with every embedded apostrophe already
-- doubled, before it reaches this query (component transform: value.replace("'", "''")). A
-- single-value multi-select (one item in the list) is regression-tested to behave identically
-- to the old single-dropdown `=` filter.
--
-- All 5 slice-able dimensions are filterable here so they can be layered together (e.g.
-- Team + MSP + DealType at once, per Kevin's "provide detail to the lowest level of
-- granularity" ask) -- not just the dimension currently selected as the row grouping.
--
-- DSMB EXCLUSION (base filter, permanent, not a toggle) -- confirmed 2026-07-27: this whole
-- dashboard is scoped to SMB+, DSMB excluded. DSMB is defined by ACCOUNT SIZE (a PMC with
-- <=750 total units), NOT by segment label or team ownership -- both of those were tested
-- against real data and don't hold: HUBSPOT_COMPANY_SEGMENT = 'Deep SMB' includes 2,024 rows
-- with >750 units (some over 100k), and plenty of "SMB"-segment rows are <=750 units. Also
-- confirmed OK on purpose: an SMB rep can carry a DSMB-sized account in their book (legacy
-- from before a workstream migration) -- exclusion is by ACCOUNT SIZE only, never by which
-- rep/team owns the deal.
-- Uses each PMC's CURRENT live unit total (summed fresh below), not the stored
-- HUBSPOT_DEAL_TOTAL_COMPANY_UNITS field -- that field is a deal-time snapshot and disagrees
-- with current reality on ~13% of PMCs (267 of 2,011 tested), which matters for a dashboard
-- that's supposed to reflect right-now, not whatever a HubSpot deal property said when it
-- was last touched.
--
-- SEGMENT BUCKET (added 2026-07-28, confirmed with Kevin) -- Sham wants the primary grouping
-- to be by SEGMENT (Strategic / MM+Ent / SMB / House Accounts), not raw pod name. Real pod
-- names don't map 1:1 onto that -- some pod labels are STALE (Cory's Team: Cory used to
-- manage a pod, he's now an individual contributor on Strategic Team -- Heidi's Team: Heidi has
-- left the company, Dana Finch runs that pod now -- also resolves oneonone_prep.sql's
-- previously-unconfirmed Dana pod mapping) -- so this is a name-to-segment mapping, not a
-- literal rename. Confirmed mapping (validated live against 3 months of real unit volume):
--   MM/Ent          <- Brandon's Team
--   Strategic       <- Strategic Team, Cory's Team, Heidi's Team
--   SMB             <- SMB Account Executives, SMB Account Executives 1, SMB Account Executives 2
--   House Accounts  <- House Accounts (Morgan Giles only, per Kevin -- one rep, kept as its
--                      own segment anyway since Sham thinks of it as a distinct bucket)
--   Not Set         <- HUBSPOT_STATIC_TEAM_NAME_DEAL IS NULL (2.4M units/3mo, real volume --
--                      kept visible, not silently dropped, so Sham can see there's real
--                      unattributed volume rather than have it vanish from the total)
-- Everything else -- DSMB 1-5, Deep SMB *, DSMB Account Executive (External), Partner
-- Success, Partner GTM, Channel Sales, all SDR-only pods, leadership-only pods (Strategic
-- Team Leadership, House Accounts Leadership), and the tiny legacy "Historical
-- MM/Enterprise"/"Historical Strategic" tags -- gets segment_bucket = NULL and is EXCLUDED
-- entirely from this query's output (per Kevin: "we dont want dsmb or partner success...we
-- do want sdrs but i think we can remove them for now too"). This is a different exclusion
-- than the DSMB account-size filter above -- that one drops small ACCOUNTS regardless of who
-- owns them -- this one drops specific ORG PODS from the segment-level view regardless of
-- account size. Both apply, independently.
--
-- TEAM BUCKET (added 2026-07-28) -- a SECOND, NARROWER mapping than segment_bucket, for the
-- Team filter specifically. Sham's 4 direct-report units-side managers: Brandon, Rory,
-- Sebastian, Dana -- "all we want are Brandons team, rory's team, seba, and dana" (Hans is
-- SDR-side, not in this units-side query at all). Different from segment_bucket in two ways:
-- (1) SMB splits into Rory's Team / Sebastian's Team here instead of collapsing to one "SMB"
-- bucket, since Team needs to distinguish the two managers -- (2) House Accounts and Not Set
-- are NOT valid Team values (no direct-report manager owns them) even though they ARE valid
-- Segment values -- segment_bucket and team_bucket are independent, don't expect them to
-- agree row for row. Confirmed live volume: Dana's Team 12.78M units/3mo (includes the
-- Cory's Team / Heidi's Team stale labels), Brandon's Team 12.97M, Sebastian's Team 3.2M,
-- Rory's Team 2.68M.
--
-- DEPARTED-REP EXCLUSION (2026-07-29) -- Kevin: "this rep in this team taylor mobley hasnt
-- been w the company in a year - why is she appearing in rolled out?" Root cause: the legacy
-- unnumbered "SMB Account Executives" pod (distinct from "...1"/"...2") has exactly ONE
-- contributor this month, and it's Taylor Mobley -- her 189 units are real (a property from an
-- old deal just finished integrating, a normal rollout lag), but HUBSPOT_DEAL_OWNER is a
-- static HubSpot snapshot with no employment-status concept at all, so she shows up as if
-- current. This was also the entire "extra team" row Kevin spotted under SMB in the Rolled-Out
-- drill that Closed Won didn't show (that card's team_bucket mapping already excludes the
-- unnumbered pod from team-level -- this one didn't have an equivalent guard on the rep itself).
-- Fix: join deal_owner_status (same deduped-STG_SALESFORCE__USER + {{ GraceMonths.value }}
-- grace-period pattern as rep_leaderboard.sql) and drop any row whose HUBSPOT_DEAL_OWNER is
-- departed beyond the grace window -- same rule already applied and Kevin-approved elsewhere
-- in this repo, now consistent here too. Segment/team TOTALS shrink by whatever a departed
-- rep's stale volume was (189 units here -- immaterial against multi-million segment totals),
-- which is the right tradeoff: an accurate-to-the-unit total that includes a phantom current
-- rep is worse than a total that's off by a rounding error but never shows someone who left a
-- year ago as active.

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
        END AS team_bucket
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
)
SELECT
    DATE_TRUNC('month', s.BP_MONTH)                          AS bp_month,
    s.segment_bucket,
    s.team_bucket,
    COALESCE({{ Dimension.value }}, 'Not Set')               AS slice,
    SUM(IFF(s.IS_INTEGRATED_TOTAL, s.PROPERTY_UNIT_COUNT, 0))          AS integrated_total_units,
    SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0))            AS new_integrated_units,
    SUM(IFF(s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER,
            s.PROPERTY_UNIT_COUNT, 0))                                 AS recaptured_units,
    SUM(IFF(s.IS_NEW_ROLLOUT AND NOT s.IS_RECAPTURED_NEW_ROLLOUT
            AND NOT s.IS_RECAPTURED_OTHER, s.PROPERTY_UNIT_COUNT, 0))   AS new_units,
    SUM(IFF(s.IS_DEACTIVATED, s.PROPERTY_UNIT_COUNT, 0))               AS deactivated_units,
    SUM(s.ROLLED_OUT_UNITS_MOM_CHANGE)                                  AS net_change_units,
    -- 3-month trailing average of new_integrated_units, added 2026-07-30 -- same "was this
    -- month decent, or just noisy" question as rolled_out_units_daily_trend.sql's rolling_avg_7d
    -- (see that file's header for the full reasoning), just monthly grain here so a 3-month
    -- window is the equivalent smoothing length. PARTITION BY the same 3 grouping columns this
    -- query already groups by, so each segment/team/slice series gets its own independent
    -- trailing average rather than blending unrelated series together.
    AVG(SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)))
        OVER (PARTITION BY s.segment_bucket, s.team_bucket, COALESCE({{ Dimension.value }}, 'Not Set')
              ORDER BY DATE_TRUNC('month', s.BP_MONTH)
              ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)               AS new_integrated_units_rolling_avg_3mo,
    -- Dual time comparison (Debrief restructure, docs/superpowers/specs/2026-08-05-debrief-
    -- restructure-design.md, item 7) -- Box 2's Time picker needs both a prior-period value and
    -- a trailing average alongside whatever period Sham is inspecting. Applied to
    -- new_integrated_units specifically (the same metric this file already trend-tracks via
    -- new_integrated_units_rolling_avg_3mo just above), not a new metric -- month grain per the
    -- spec leads with prior-period as primary, trailing average as secondary -- unlike the 3mo avg
    -- above, this trailing average EXCLUDES the current row (6 PRECEDING AND 1 PRECEDING) so it
    -- can serve as an independent comparison baseline rather than double-counting the row it's
    -- being compared against.
    LAG(SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)))
        OVER (PARTITION BY s.segment_bucket, s.team_bucket, COALESCE({{ Dimension.value }}, 'Not Set')
              ORDER BY DATE_TRUNC('month', s.BP_MONTH))                AS new_integrated_units_prior_period,
    AVG(SUM(IFF(s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0)))
        OVER (PARTITION BY s.segment_bucket, s.team_bucket, COALESCE({{ Dimension.value }}, 'Not Set')
              ORDER BY DATE_TRUNC('month', s.BP_MONTH)
              ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING)               AS new_integrated_units_trailing_avg_6mo
FROM base s
LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
LEFT JOIN deal_owner_status u ON u.FULL_NAME = s.HUBSPOT_DEAL_OWNER
-- LookbackMonths needs a Superblocks component default (e.g. 6) -- if this binding is ever
-- empty, DATEADD(month, -, ...) is a syntax error, not a "no filter applied" no-op.
-- Resolved from MAX(BP_MONTH), not CURRENT_DATE() -- calendar month != current BP month
-- (e.g. 2026-07-27 sits inside "Aug BP 2026") -- same bug class fixed elsewhere in this repo.
WHERE s.BP_MONTH >= DATEADD(month, -{{ LookbackMonths.value }}, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
  -- DSMB exclusion: only drop a PMC when we can affirmatively confirm it's <=750 units.
  -- p.pmc_current_units IS NULL means the PMC has no in-network rows this month (e.g. fully
  -- deactivated) -- don't silently drop those, that's a different question than DSMB sizing.
  AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
  -- excluded org pods (DSMB/Partner Success/SDR/leadership/legacy) -- see header comment
  AND s.segment_bucket IS NOT NULL
  -- departed-rep exclusion: keep if no user record match (don't punish a join miss), OR
  -- currently active, OR inactive but logged in within the grace window
  AND (u.FULL_NAME IS NULL OR u.IS_ACTIVE OR u.LAST_LOGIN_AT_UTC >= DATEADD(month, -{{ GraceMonths.value }}, CURRENT_DATE()))
  {{#Team.value}}     AND s.team_bucket IN ({{Team.value}})                       {{/Team.value}}
  {{#Msp.value}}       AND s.PMS IN ({{Msp.value}})                                {{/Msp.value}}
  {{#DealType.value}}  AND s.HUBSPOT_DEAL_TYPE IN ({{DealType.value}})             {{/DealType.value}}
  {{#Segment.value}}   AND s.segment_bucket IN ({{Segment.value}})                 {{/Segment.value}}
  {{#Rep.value}}        AND s.HUBSPOT_DEAL_OWNER IN ({{Rep.value}})                {{/Rep.value}}
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2, 3, 4;
