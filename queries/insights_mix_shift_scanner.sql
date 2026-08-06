-- Mix Shift Scanner -- Kevin: "trends for all major msps (mix too - not only knowing if one
-- msp is increasing or decreasing but the total mix of units across msps)... team is weighted
-- too heavily on expansion deals, push the team on new logos... new vs recaptured." Companion
-- to insights_declining_streaks.sql (which scans RAW VOLUME for a decline) -- this scans SHARE
-- (composition) for a sustained multi-month move, reusing insights_mix_shift.sql's already-
-- validated share formulas (expansion_share, recapture_share, is_recapture boolean) but
-- generalized from ONE company/team series to every entity scanned at once, via the same
-- gaps-and-islands + partition-key technique as insights_declining_streaks.sql.
--
-- WHY NOT A FIXED SKEW THRESHOLD -- tried this first, checked live before committing to it:
-- pulled 8 months of real expansion_share by team. Dana's Team (Strategic) runs 85-100%
-- Expansion most months -- Brandon's Team (MM/Ent) runs 58-98%. That's their STRUCTURAL norm
-- (larger, more established accounts naturally see more expansion activity), not a risk
-- signal -- a fixed ">65% = too skewed" band would permanently flag both of them every single
-- month, which is exactly the "cry wolf" noise this repo has avoided elsewhere (materiality
-- floors, pacing-comparison bans). Fixed by using the SAME streak technique as
-- insights_declining_streaks.sql, applied to the SHARE ratio instead of raw units --
-- "expansion_share has moved the same direction for N straight months" is meaningful for any
-- team regardless of its baseline level, "expansion_share is currently above X%" is not.
--
-- BOTH DIRECTIONS SURFACE HERE, UNLIKE insights_declining_streaks.sql -- a rising Expansion
-- share isn't inherently bad (could mean strong upsell execution) and a falling one isn't
-- inherently good -- this is a MIX signal, not a decline/growth one, so both directions are
-- worth knowing about. The narration layer decides whether "shifting toward Expansion" or
-- "shifting toward New Logo" is the more actionable framing given the direction and the team's
-- history, not this query.
--
-- GRANULARITY ADDED 2026-08-04 -- `{{ Granularity.value }}` = 'Month' | 'Quarter', same
-- `DATE_TRUNC('quarter', BP_MONTH)` technique as insights_declining_streaks.sql (BP_MONTH is
-- already a calendar-month-labeled date, so this directly yields the correct BP-quarter
-- grouping -- confirmed live with Kevin: Jul/Aug/Sep BP all truncate to the same quarter
-- bucket, matching "BP Q3 = Jul BP - Sep BP"). Lookback widened 12->24 months for the same
-- reason as that file. Week not offered here, same rationale.
--
-- MSP/REP CUTS ON PART B, added 2026-08-05 (Debrief restructure, docs/superpowers/specs/2026-
-- 08-05-debrief-restructure-design.md) -- Part B now has ALL 4 breakout cuts: Team (original
-- Part B), Segment (Part B-Segment), MSP (Part B-MSP), Rep (Part B-Rep). The two new cuts
-- (MSP, Rep) are structural copies of Part B (Team)/Part B-Segment, same CTE chain and
-- gaps-and-islands streak technique, only the partition key changes: msp resolved via the same
-- account-level DIM_SALES_ACCOUNTS join niro_units_cube.sql already validated (this file had no
-- existing DIM_SALES_ACCOUNTS join to reuse -- checked before adding one), and rep =
-- HUBSPOT_DEAL_OWNER, the same rep-name column every other rep cut in this repo uses directly.
-- Both COALESCE an unresolved value to 'Not Set' rather than dropping the row, so each cut's
-- total_units reconciles EXACTLY against Part B-Segment's total for the same period (RECONCILED
-- LIVE against BP_MONTH = 2026-08-01: Segment/MSP/Rep all summed to 308,855 total_units /
-- 209,599 Expansion units for that period). NOT Part B/Team's total -- Team's own HAVING clause
-- already excludes House Accounts and plain 'SMB Account Executives' rows that don't map to a
-- team_bucket (Team's total for that same period was 293,276, a pre-existing gap this change
-- didn't introduce), so Team's total is always a strict subset of Segment's, never the
-- reconciliation target. Real Not Set rate for that period: MSP 5.82% (17,981 of 308,855
-- units, a genuine account-MSP coverage gap, not a join failure -- see Part B-MSP's header),
-- Rep 0% (see Part B-Rep's header) -- both notably lower than Task 5's ~39% deactivation
-- Not Set rate, as expected for a different population. Neither offers a DealType.value filter
-- -- see Part B-MSP's header below for why filtering on the exact dimension this scanner
-- measures (expansion_share is a HUBSPOT_DEAL_TYPE split) would be self-defeating. Only the two
-- NEW cuts (MSP, Rep) got multi-select filters + dual time comparison in this pass -- Part
-- B/Part B-Segment (Team/Segment) still have neither, which matches this task's exact scope
-- (asked only to extend Part B's MSP/Rep cuts), not an oversight -- don't assume all 4 Part B
-- cuts are equally filterable when wiring Superblocks (Task 9). Part C/Part C-Segment (New vs.
-- Recaptured) were NOT extended with MSP/Rep cuts here -- out of scope for this task, which
-- asked only for Part B.

-- Part A: MSP share-of-total-units trend, ALL MSPs scanned at once.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
base AS (
    SELECT
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        s.PMS, s.PROPERTY_UNIT_COUNT
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -24, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
),
month_totals AS (
    SELECT period, SUM(PROPERTY_UNIT_COUNT) AS month_total FROM base GROUP BY 1
),
monthly AS (
    SELECT COALESCE(b.PMS, 'Not Set') AS msp, b.period,
        DIV0(SUM(b.PROPERTY_UNIT_COUNT), mt.month_total) AS share
    FROM base b
    JOIN month_totals mt ON b.period = mt.period
    GROUP BY 1, 2, mt.month_total
    HAVING SUM(b.PROPERTY_UNIT_COUNT) >= 1000
),
with_change AS (
    SELECT *, SIGN(share - LAG(share) OVER (PARTITION BY msp ORDER BY period)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY msp ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY msp ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    -- MAX_BY (not the MIN-exploits-monotonicity trick used in insights_declining_streaks.sql)
    -- because this file surfaces BOTH directions, so "latest = smallest" doesn't hold here.
    SELECT msp, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_month, MAX_BY(share, period) AS latest_share
    FROM with_group
    GROUP BY msp, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY msp)
)
SELECT msp, chg_sign AS direction, streak_len AS streak_months, latest_month, ROUND(latest_share, 4) AS latest_share
FROM streaks
-- MAJOR MSPs ONLY -- Kevin asked for "all major MSPs," and a raw unit floor alone isn't
-- enough: AMC Rent Pay cleared the 1000-unit floor above but its actual SHARE of the total is
-- 0.37% -- a real move on an irrelevant MSP isn't a "major MSP" signal. `latest_share >= 0.02`
-- (2%) keeps the query focused on MSPs that matter to the business shape, not every minor one.
WHERE streak_len >= {{ MinStreakMonths.value }} AND latest_share >= 0.02
ORDER BY streak_months DESC;

-- Part B: New Logo vs. Expansion share streak, by TEAM -- generalizes ai_summary_facts.sql
-- Part E from a single {{ Team.value }}-filtered series to all 4 AE pods scanned at once.
-- Same "both directions surface" reasoning as Part A above -- confirmed live before writing
-- this that Dana's/Brandon's Teams structurally run 60-100% Expansion share most months
-- (larger, more established accounts), so a fixed skew threshold would flag them permanently --
-- streak-on-direction avoids that false-alarm problem entirely.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        DIV0(SUM(IFF(s.HUBSPOT_DEAL_TYPE = 'Expansion', s.PROPERTY_UNIT_COUNT, 0)), SUM(s.PROPERTY_UNIT_COUNT)) AS expansion_share,
        SUM(s.PROPERTY_UNIT_COUNT) AS total_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -24, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING team_bucket IS NOT NULL AND total_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(expansion_share - LAG(expansion_share) OVER (PARTITION BY team_bucket ORDER BY period)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY team_bucket ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY team_bucket ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT team_bucket, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_month, MAX_BY(expansion_share, period) AS latest_expansion_share
    FROM with_group
    GROUP BY team_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY team_bucket)
)
SELECT team_bucket, chg_sign AS direction, streak_len AS streak_months, latest_month, ROUND(latest_expansion_share, 4) AS latest_expansion_share
FROM streaks
WHERE streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;

-- Part B-Segment: same as Part B, PARTITION BY segment_bucket instead of team_bucket --
-- SMB is 1 segment but 2 teams, so a segment-level mix shift can be real even when neither
-- individual SMB team's own streak (Part B) crosses the threshold on its own.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        DIV0(SUM(IFF(s.HUBSPOT_DEAL_TYPE = 'Expansion', s.PROPERTY_UNIT_COUNT, 0)), SUM(s.PROPERTY_UNIT_COUNT)) AS expansion_share,
        SUM(s.PROPERTY_UNIT_COUNT) AS total_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -24, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL AND total_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(expansion_share - LAG(expansion_share) OVER (PARTITION BY segment_bucket ORDER BY period)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY segment_bucket ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY segment_bucket ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT segment_bucket, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_month, MAX_BY(expansion_share, period) AS latest_expansion_share
    FROM with_group
    GROUP BY segment_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY segment_bucket)
)
SELECT segment_bucket, chg_sign AS direction, streak_len AS streak_months, latest_month, ROUND(latest_expansion_share, 4) AS latest_expansion_share
FROM streaks
WHERE streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;

-- Part B-MSP: same as Part B, PARTITION BY msp instead of team_bucket -- msp resolved via the
-- same account-level DIM_SALES_ACCOUNTS join niro_units_cube.sql already validated
-- (HUBSPOT_COMPANY_ID = ACCOUNT_SALESFORCE_ID, confirmed 1:1, no fan-out) -- property-level PMS
-- isn't populated for deactivated/non-integrated properties, so it can't be reused here, same
-- reasoning as every other MSP cut in this repo. Unresolved MSP is COALESCE'd to 'Not Set'
-- rather than dropped, so this cut's total unit volume reconciles EXACTLY against Part
-- B-Segment's total for the same period -- not against Part B/Team's total, which is always a
-- strict subset of Segment's (see the file's top-of-file header for why). RECONCILED LIVE
-- against BP_MONTH = 2026-08-01: Segment/MSP both totaled 308,855 units / 209,599 Expansion
-- units for that period. Real MSP Not Set rate for that period: 5.82% (17,981 of 308,855
-- units) -- a genuine account-MSP coverage gap (accounts with no DIM_SALES_ACCOUNTS match, not
-- a broken join -- the join itself is confirmed 1:1 by the reconciliation above), materially
-- lower than Task 5's ~39% deactivation Not Set rate since this is a different population
-- (new-rollout deals, not the deactivation base).
--
-- MULTI-SELECT FILTERS + DUAL TIME COMPARISON, added 2026-08-05 (Debrief restructure,
-- docs/superpowers/specs/2026-08-05-debrief-restructure-design.md) -- Team.value/Segment.value/
-- Msp.value/Rep.value narrow the underlying population before the mix is computed, same
-- IN (...) convention every other cube in this repo uses (`scoped` below carries segment_
-- bucket/team_bucket/msp regardless of this Part's own breakout key so all 4 filters can layer
-- together, same technique insights_net_units_bridge.sql's Parts B/B2/B3/B4 already use).
-- DealType.value is DELIBERATELY NOT OFFERED HERE (nor on Part B-Rep below) -- this Part's own
-- headline metric (expansion_share) IS a split on HUBSPOT_DEAL_TYPE, so filtering the
-- underlying rows to a single deal type would trivially force every entity's share to 0% or
-- 100% (numerator = denominator) and erase the exact mix signal this scanner exists to surface
-- -- a "don't filter the thing you're measuring" exclusion, not an oversight.
-- latest_expansion_share_prior_period/latest_expansion_share_trailing_avg_6period extend
-- expansion_share, the metric this Part already trend-tracks via its own pre-existing chg_sign
-- LAG -- not a new metric (dual time comparison naming convention, plan preamble). Named
-- "_6period" not "_6mo" since this file supports Month OR Quarter via {{ Granularity.value }}.
--
-- POPULATION CONSISTENCY -- gated on the SAME `segment_bucket IS NOT NULL` scope Part B/Part
-- B-Segment already enforce (via their own HAVING clauses) -- same "POPULATION-CONSISTENCY
-- BUG" class insights_net_units_bridge.sql's header documents and fixed live: without this
-- gate, MSP would include DSMB/Partner Success/SDR-only/leadership-pod rows that Team/Segment
-- exclude, so MSP's total would run HIGHER than Team/Segment's, not reconcile against it.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        COALESCE(acct.ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES, 'Not Set') AS msp
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN PRODUCTION.SALES.DIM_SALES_ACCOUNTS acct
        ON s.HUBSPOT_COMPANY_ID = acct.ACCOUNT_SALESFORCE_ID
),
monthly AS (
    SELECT
        sc.msp,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', sc.BP_MONTH), sc.BP_MONTH) AS period,
        DIV0(SUM(IFF(sc.HUBSPOT_DEAL_TYPE = 'Expansion', sc.PROPERTY_UNIT_COUNT, 0)), SUM(sc.PROPERTY_UNIT_COUNT)) AS expansion_share,
        SUM(sc.PROPERTY_UNIT_COUNT) AS total_units
    FROM scoped sc
    LEFT JOIN pmc_size p ON sc.PMC_ID = p.PMC_ID
    WHERE sc.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND sc.BP_MONTH >= DATEADD(month, -24, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
      AND sc.segment_bucket IS NOT NULL
      {{#Team.value}}    AND sc.team_bucket    IN ({{Team.value}})    {{/Team.value}}
      {{#Segment.value}} AND sc.segment_bucket IN ({{Segment.value}}) {{/Segment.value}}
      {{#Msp.value}}     AND sc.msp            IN ({{Msp.value}})     {{/Msp.value}}
      {{#Rep.value}}     AND sc.HUBSPOT_DEAL_OWNER IN ({{Rep.value}}) {{/Rep.value}}
    GROUP BY 1, 2
    HAVING total_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *,
        SIGN(expansion_share - LAG(expansion_share) OVER (PARTITION BY msp ORDER BY period)) AS chg_sign,
        LAG(expansion_share) OVER (PARTITION BY msp ORDER BY period) AS expansion_share_prior_period,
        AVG(expansion_share) OVER (PARTITION BY msp ORDER BY period ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS expansion_share_trailing_avg_6period
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY msp ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY msp ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT msp, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_month,
        MAX_BY(expansion_share, period) AS latest_expansion_share,
        MAX_BY(expansion_share_prior_period, period) AS latest_expansion_share_prior_period,
        MAX_BY(expansion_share_trailing_avg_6period, period) AS latest_expansion_share_trailing_avg_6period
    FROM with_group
    GROUP BY msp, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY msp)
)
SELECT
    msp, chg_sign AS direction, streak_len AS streak_months, latest_month,
    ROUND(latest_expansion_share, 4) AS latest_expansion_share,
    ROUND(latest_expansion_share_prior_period, 4) AS latest_expansion_share_prior_period,
    ROUND(latest_expansion_share_trailing_avg_6period, 4) AS latest_expansion_share_trailing_avg_6period
FROM streaks
WHERE streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;

-- Part B-Rep: same as Part B, PARTITION BY rep (HUBSPOT_DEAL_OWNER) instead of team_bucket --
-- HUBSPOT_DEAL_OWNER is already the rep-name column every other file in this repo uses directly
-- (e.g. shout_outs_facts.sql, insights_net_units_bridge.sql's Part B4). A missing rep is
-- COALESCE'd to 'Not Set' (same reasoning as MSP above -- keep unresolved volume visible
-- instead of dropping it, so this cut also reconciles EXACTLY against Part B-Segment's total,
-- not against Part B/Team's, same distinction as Part B-MSP above). RECONCILED LIVE against
-- BP_MONTH = 2026-08-01: Rep cut also totaled 308,855 units / 209,599 Expansion units for that
-- period, matching Segment/MSP exactly. Real Rep Not Set rate for that period: 0% (every
-- IS_NEW_ROLLOUT row in that month had a populated HUBSPOT_DEAL_OWNER) -- unlike MSP, no
-- coverage gap observed for this cut in the period checked.
--
-- DEPARTED-REP GRACE PERIOD DELIBERATELY NOT APPLIED HERE -- same reasoning as insights_net_
-- units_bridge.sql's Part B4 header: this Part's expansion_share is built off IS_NEW_ROLLOUT, a
-- FLOW event tied to a specific historical BP_MONTH, not a live stock total, so a departed
-- rep's name against a real historical mix-shift event is useful information (who was driving
-- New Logo vs. Expansion before they left), not noise.
--
-- MULTI-SELECT FILTERS + DUAL TIME COMPARISON, added 2026-08-05 -- same convention and same
-- DealType.value exclusion rationale as Part B-MSP above (this Part's own metric already splits
-- on HUBSPOT_DEAL_TYPE, so offering it as a filter here would trivially force every entity's
-- share to 0%/100%). Same POPULATION CONSISTENCY gate as Part B-MSP (segment_bucket IS NOT
-- NULL) so this cut's total also reconciles against Part B/Part B-Segment, not just Part B-MSP.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
scoped AS (
    SELECT s.*,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        COALESCE(acct.ACCOUNT_PROPERTY_MANAGEMENT_SOFTWARES, 'Not Set') AS msp,
        COALESCE(s.HUBSPOT_DEAL_OWNER, 'Not Set') AS rep
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN PRODUCTION.SALES.DIM_SALES_ACCOUNTS acct
        ON s.HUBSPOT_COMPANY_ID = acct.ACCOUNT_SALESFORCE_ID
),
monthly AS (
    SELECT
        sc.rep,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', sc.BP_MONTH), sc.BP_MONTH) AS period,
        DIV0(SUM(IFF(sc.HUBSPOT_DEAL_TYPE = 'Expansion', sc.PROPERTY_UNIT_COUNT, 0)), SUM(sc.PROPERTY_UNIT_COUNT)) AS expansion_share,
        SUM(sc.PROPERTY_UNIT_COUNT) AS total_units
    FROM scoped sc
    LEFT JOIN pmc_size p ON sc.PMC_ID = p.PMC_ID
    WHERE sc.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND sc.BP_MONTH >= DATEADD(month, -24, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
      AND sc.segment_bucket IS NOT NULL
      {{#Team.value}}    AND sc.team_bucket    IN ({{Team.value}})    {{/Team.value}}
      {{#Segment.value}} AND sc.segment_bucket IN ({{Segment.value}}) {{/Segment.value}}
      {{#Msp.value}}     AND sc.msp            IN ({{Msp.value}})     {{/Msp.value}}
      {{#Rep.value}}     AND sc.rep            IN ({{Rep.value}})     {{/Rep.value}}
    GROUP BY 1, 2
    HAVING total_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *,
        SIGN(expansion_share - LAG(expansion_share) OVER (PARTITION BY rep ORDER BY period)) AS chg_sign,
        LAG(expansion_share) OVER (PARTITION BY rep ORDER BY period) AS expansion_share_prior_period,
        AVG(expansion_share) OVER (PARTITION BY rep ORDER BY period ROWS BETWEEN 6 PRECEDING AND 1 PRECEDING) AS expansion_share_trailing_avg_6period
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY rep ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY rep ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT rep, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_month,
        MAX_BY(expansion_share, period) AS latest_expansion_share,
        MAX_BY(expansion_share_prior_period, period) AS latest_expansion_share_prior_period,
        MAX_BY(expansion_share_trailing_avg_6period, period) AS latest_expansion_share_trailing_avg_6period
    FROM with_group
    GROUP BY rep, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY rep)
)
SELECT
    rep, chg_sign AS direction, streak_len AS streak_months, latest_month,
    ROUND(latest_expansion_share, 4) AS latest_expansion_share,
    ROUND(latest_expansion_share_prior_period, 4) AS latest_expansion_share_prior_period,
    ROUND(latest_expansion_share_trailing_avg_6period, 4) AS latest_expansion_share_trailing_avg_6period
FROM streaks
WHERE streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;

-- Part C: New vs. Recaptured share streak, by TEAM and SEGMENT -- same technique as Part B,
-- `is_recapture` boolean copied verbatim from insights_mix_shift.sql (broader than the
-- IS_RECAPTURED_NEW_ROLLOUT/IS_RECAPTURED_OTHER pair alone -- includes the NON_INTEGRATED
-- recapture variants too, matching that file's own already-validated definition).
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        DIV0(SUM(IFF(s.IS_RECAPTURED_OTHER OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_NON_INTEGRATED_RECAPTURED_OTHER OR s.IS_NON_INTEGRATED_RECAPTURED_NEW_ROLLOUT, s.PROPERTY_UNIT_COUNT, 0)), SUM(s.PROPERTY_UNIT_COUNT)) AS recapture_share,
        SUM(s.PROPERTY_UNIT_COUNT) AS total_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -24, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING team_bucket IS NOT NULL AND total_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(recapture_share - LAG(recapture_share) OVER (PARTITION BY team_bucket ORDER BY period)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY team_bucket ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY team_bucket ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT team_bucket, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_month, MAX_BY(recapture_share, period) AS latest_recapture_share
    FROM with_group
    GROUP BY team_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY team_bucket)
)
SELECT team_bucket, chg_sign AS direction, streak_len AS streak_months, latest_month, ROUND(latest_recapture_share, 4) AS latest_recapture_share
FROM streaks
WHERE streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;

-- Part C-Segment: same as Part C, PARTITION BY segment_bucket.
WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
monthly AS (
    SELECT
        CASE
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN s.HUBSPOT_STATIC_TEAM_NAME_DEAL = 'House Accounts' THEN 'House Accounts'
            ELSE NULL
        END AS segment_bucket,
        IFF('{{ Granularity.value }}' = 'Quarter', DATE_TRUNC('quarter', s.BP_MONTH), s.BP_MONTH) AS period,
        DIV0(SUM(IFF(s.IS_RECAPTURED_OTHER OR s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_NON_INTEGRATED_RECAPTURED_OTHER OR s.IS_NON_INTEGRATED_RECAPTURED_NEW_ROLLOUT, s.PROPERTY_UNIT_COUNT, 0)), SUM(s.PROPERTY_UNIT_COUNT)) AS recapture_share,
        SUM(s.PROPERTY_UNIT_COUNT) AS total_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
    LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
    WHERE s.IS_NEW_ROLLOUT AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND s.BP_MONTH >= DATEADD(month, -24, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
    GROUP BY 1, 2
    HAVING segment_bucket IS NOT NULL AND total_units >= {{ MinUnitsFloor.value }}
),
with_change AS (
    SELECT *, SIGN(recapture_share - LAG(recapture_share) OVER (PARTITION BY segment_bucket ORDER BY period)) AS chg_sign
    FROM monthly
),
with_lag AS (
    SELECT *, LAG(chg_sign) OVER (PARTITION BY segment_bucket ORDER BY period) AS prev_sign
    FROM with_change WHERE chg_sign IS NOT NULL AND chg_sign != 0
),
with_group AS (
    SELECT *, SUM(IFF(chg_sign != prev_sign OR prev_sign IS NULL, 1, 0)) OVER (PARTITION BY segment_bucket ORDER BY period) AS grp
    FROM with_lag
),
streaks AS (
    SELECT segment_bucket, chg_sign, COUNT(*) AS streak_len, MAX(period) AS latest_month, MAX_BY(recapture_share, period) AS latest_recapture_share
    FROM with_group
    GROUP BY segment_bucket, grp, chg_sign
    QUALIFY latest_month = MAX(latest_month) OVER (PARTITION BY segment_bucket)
)
SELECT segment_bucket, chg_sign AS direction, streak_len AS streak_months, latest_month, ROUND(latest_recapture_share, 4) AS latest_recapture_share
FROM streaks
WHERE streak_len >= {{ MinStreakMonths.value }}
ORDER BY streak_months DESC;
