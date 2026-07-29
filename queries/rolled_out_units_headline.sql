-- Rolled-Out Units, Headline Strip -- feeds the front-dashboard summary table alongside
-- Calls/Emails/Meetings/Demos/Closed Won/Closed Lost. Kevin: "this is showing the total units
-- [stock]. i think we want to see this months additions... instead of one number on one row
-- we show 6 numbers (2 in each column comparing current vs last). so this week last week gets
-- two numbers, this month last month etc." Matches the existing row layout exactly: This
-- Week/Last Week, This Month/Last Month, This Quarter/Last Quarter -- NET ADDS (flow), not the
-- cumulative network total (stock) that was there before. Same stock-vs-flow distinction as
-- rolled_out_units_cube.sql -- if Kevin also wants the total-network-size number visible, that
-- should be a separate trended bar chart bound to rolled_out_units_cube.sql's
-- integrated_total_units column (already exists, already filterable), not this row.
--
-- NO PROJECTED PACING, BUT SHOW A PLAIN DELTA % -- same principle as Closed Won/Closed Lost on
-- this same summary table (see performance_cube.sql's header, refined 2026-07-29): this uses
-- the "_full" comparator (last_week_full, not a same-elapsed-day pacing-matched partial week)
-- because rollout timing is arbitrary -- a same-elapsed-day comparison would be close to a coin
-- flip. But a plain %-delta between the two numbers this query already returns (this_week vs
-- last_week_full, etc.) is a real, honest, non-projected statement, not a banned pacing
-- extrapolation -- show it with the same arrow+% widget the activity rows use.
--
-- WEEKLY GRAIN IS NEW, VALIDATED LIVE 2026-07-29 -- this is the first week-level cut of
-- rolled-out units in this repo. Initially assumed impossible ("property-grain, updates
-- monthly not weekly" was the UI's own prior assumption) -- turned out wrong.
-- PROPERTY_BP_MONTH_STATS.ROLLOUT_DATE carries real day-level precision and varies genuinely
-- within a BP month (confirmed live: current BP month's IS_NEW_INTEGRATED rows spread across
-- 4 distinct weeks, not all dumped on one date) -- FIRST_ROLLOUT_DATE does NOT (confirmed
-- live it's always just the 1st of the BP month's calendar month, a derived/rounded field,
-- useless for this). Week view filters IS_NEW_INTEGRATED rows by ROLLOUT_DATE falling in the
-- calendar week, with NO BP_MONTH constraint (a week can straddle two BP months near the
-- 5th-of-month boundary, same as every other weekly cut in this repo).
--
-- MONTH/QUARTER STAYS ON THE ESTABLISHED BP_MONTH-FLAG BASIS, DELIBERATELY NOT ROLLOUT_DATE --
-- checked live: SUM(units) via ROLLOUT_DATE-windowed-to-BP-month reconciles to within ~1-2% of
-- the official BP_MONTH-flag total (a few rollouts land a day or two outside their assigned
-- BP-month window -- real, minor, not worth chasing), but using ROLLOUT_DATE only for the
-- month/quarter numbers here would introduce a small, confusing mismatch against every other
-- query in this repo that already reports new_integrated_units by BP_MONTH (rolled_out_
-- units_cube.sql, rep_leaderboard.sql, etc). Month/quarter here are IDENTICAL in method to
-- those -- only the week-level number is genuinely new and uses a different (necessarily
-- different, there's no other way) basis.
--
-- Same DSMB exclusion (PMC current live units > 750) and segment_bucket/team_bucket mapping
-- as rolled_out_units_cube.sql -- same filters, so this headline row and the detailed
-- breakdown page stay consistent when a filter is applied.

WITH current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
week_periods AS (
    SELECT 'this_week' AS period, DATE_TRUNC('week', CURRENT_DATE()) AS start_date, CURRENT_DATE() AS end_date FROM current_bp
    UNION ALL
    SELECT 'last_week_full', DATE_TRUNC('week', CURRENT_DATE()) - 7, DATE_TRUNC('week', CURRENT_DATE()) - 1 FROM current_bp
),
month_periods AS (
    SELECT 'this_month' AS period, bp_month_label AS bp_start, bp_month_label AS bp_end FROM current_bp
    UNION ALL
    SELECT 'last_month_full', DATEADD(month, -1, bp_month_label), DATEADD(month, -1, bp_month_label) FROM current_bp
    UNION ALL
    SELECT 'this_quarter', DATEADD(month, -2, bp_month_label), bp_month_label FROM current_bp
    UNION ALL
    SELECT 'last_quarter_full', DATEADD(month, -5, bp_month_label), DATEADD(month, -3, bp_month_label) FROM current_bp
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
    WHERE s.IS_NEW_INTEGRATED = TRUE
),
week_view AS (
    SELECT p.period, SUM(b.PROPERTY_UNIT_COUNT) AS net_adds
    FROM week_periods p
    JOIN base b ON b.ROLLOUT_DATE BETWEEN p.start_date AND p.end_date AND b.ROLLOUT_DATE IS NOT NULL
    LEFT JOIN pmc_size pm ON b.PMC_ID = pm.PMC_ID
    WHERE (pm.pmc_current_units IS NULL OR pm.pmc_current_units > 750)
      AND b.segment_bucket IS NOT NULL
      {{#Team.value}}    AND b.team_bucket = '{{Team.value}}'       {{/Team.value}}
      {{#Segment.value}} AND b.segment_bucket = '{{Segment.value}}' {{/Segment.value}}
      {{#Msp.value}}      AND b.PMS = '{{Msp.value}}'                {{/Msp.value}}
      {{#DealType.value}} AND b.HUBSPOT_DEAL_TYPE = '{{DealType.value}}' {{/DealType.value}}
    GROUP BY 1
),
month_view AS (
    SELECT p.period, SUM(b.PROPERTY_UNIT_COUNT) AS net_adds
    FROM month_periods p
    JOIN base b ON b.BP_MONTH BETWEEN p.bp_start AND p.bp_end
    LEFT JOIN pmc_size pm ON b.PMC_ID = pm.PMC_ID
    WHERE (pm.pmc_current_units IS NULL OR pm.pmc_current_units > 750)
      AND b.segment_bucket IS NOT NULL
      {{#Team.value}}    AND b.team_bucket = '{{Team.value}}'       {{/Team.value}}
      {{#Segment.value}} AND b.segment_bucket = '{{Segment.value}}' {{/Segment.value}}
      {{#Msp.value}}      AND b.PMS = '{{Msp.value}}'                {{/Msp.value}}
      {{#DealType.value}} AND b.HUBSPOT_DEAL_TYPE = '{{DealType.value}}' {{/DealType.value}}
    GROUP BY 1
)
SELECT * FROM week_view
UNION ALL
SELECT * FROM month_view
ORDER BY period;
