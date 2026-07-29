-- Closed Won, by Rep -- the drill-down underneath "Closed Won, by Team" on the Deals & Units
-- page. Per Kevin: "would be nice if you click into each team the rep names appeared and u
-- can see how they trend vs last month." Same team_bucket mapping and same New Logo/
-- Expansion/Move In deal-type scope as performance_cube.sql, just grouped one level deeper
-- (rep instead of team). Validated live 2026-07-28: Dana's Team's team-level number is not
-- evenly spread -- Cory Baach alone dropped from 62,667 to 12,490 while Evan Klein, Doron
-- David, and Ariel Kurek moved less dramatically. Confirms the same "the team average hides
-- who's actually driving it" pattern already established elsewhere in this repo
-- (insights_driver_concentration.sql).
--
-- PERIOD RESPONSIVENESS -- fixed 2026-07-28, real bug Kevin caught: this was hardcoded to
-- this_month/last_month_full only, so switching the page's Week/Month/Quarter toggle changed
-- the parent "Closed Won, by Team" card but NOT this drill-down underneath it -- the rep
-- breakdown kept showing month numbers no matter what was selected above. Fixed by returning
-- ALL THREE granularities (period column, same pattern as performance_cube.sql) so Superblocks
-- can filter to whichever pair matches the active toggle, exactly like the parent card does.
-- Uses the "_full" comparator for every granularity (this_week/last_week_full,
-- this_month/last_month_full, this_quarter/last_quarter_full) -- NOT the pacing-matched _mtd/
-- _wtd/_qtd variants -- because Closed Won units never get a pacing comparison anywhere in
-- this repo (deal timing is arbitrary, see performance_cube.sql's header for why); this
-- drill-down should never introduce a pacing comparison the parent card doesn't have either.
--
-- FILTER ESCAPING -- same apostrophe risk as every value filter in this repo.
--
-- SEGMENT/TEAM CONSOLIDATION (added 2026-07-28) -- Kevin: "consolidate the segment and team
-- and rep view... have the team just go into the segment view... these are mostly the same
-- but smb will split out into smb 1 and smb 2." Confirmed: segment_bucket and team_bucket are
-- literally the same underlying grouping except SMB -- Strategic segment = Dana's Team
-- exactly (same STATIC_TEAM_NAME values), MM/Ent = Brandon's Team exactly, House Accounts/
-- Not Set have no team_bucket at all. Only SMB splits into two real teams (Sebastian's/
-- Rory's). Added segment_bucket here so the UI can drill Segment -> Rep DIRECTLY for
-- Strategic/MM/Ent/House Accounts/Not Set (no team level needed, it'd just repeat the
-- segment), and only show an intermediate Team sub-level when SMB specifically is clicked
-- (Sebastian's vs. Rory's, via performance_cube.sql's existing team_bucket grouping filtered
-- to segment_bucket='SMB' -- no new query needed for that intermediate step).

WITH current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
bp_periods AS (
    SELECT 'this_week' AS period, DATE_TRUNC('week', CURRENT_DATE()) AS start_date, CURRENT_DATE() AS end_date
    FROM current_bp
    UNION ALL
    SELECT 'last_week_full', DATE_TRUNC('week', CURRENT_DATE()) - 7, DATE_TRUNC('week', CURRENT_DATE()) - 1
    FROM current_bp
    UNION ALL
    SELECT 'this_month',
        DATEADD(day, 4, DATEADD(month, -1, bp_month_label)),
        LEAST(DATEADD(day, 3, bp_month_label), CURRENT_DATE())
    FROM current_bp
    UNION ALL
    SELECT 'last_month_full',
        DATEADD(day, 4, DATEADD(month, -2, bp_month_label)),
        DATEADD(day, 3, DATEADD(month, -1, bp_month_label))
    FROM current_bp
    UNION ALL
    SELECT 'this_quarter',
        DATEADD(day, 4, DATEADD(month, -1, DATE_TRUNC('quarter', bp_month_label))),
        LEAST(DATEADD(day, 3, DATEADD(month, 2, DATE_TRUNC('quarter', bp_month_label))), CURRENT_DATE())
    FROM current_bp
    UNION ALL
    SELECT 'last_quarter_full',
        DATEADD(day, 4, DATEADD(month, -4, DATE_TRUNC('quarter', bp_month_label))),
        DATEADD(day, 3, DATEADD(month, -1, DATE_TRUNC('quarter', bp_month_label)))
    FROM current_bp
),
base AS (
    SELECT
        o.*,
        e.FULL_NAME AS rep,
        CASE
            WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN e.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN e.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket,
        CASE
            WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN e.TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN e.TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            WHEN e.TEAM_NAME IS NULL THEN 'Not Set'
            ELSE NULL
        END AS segment_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
    WHERE o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
)
SELECT
    p.period,
    b.rep,
    b.team_bucket,
    b.segment_bucket,
    SUM(IFF(b.IS_CLOSED_WON AND b.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date, b.FLEX_UNIT_COUNT, 0)) AS units
FROM bp_periods p
JOIN base b ON TRUE
WHERE b.rep IS NOT NULL
  {{#Team.value}}     AND b.team_bucket = '{{Team.value}}'       {{/Team.value}}
  {{#Segment.value}}  AND b.segment_bucket = '{{Segment.value}}' {{/Segment.value}}
GROUP BY 1, 2, 3, 4
HAVING units > 0
ORDER BY p.period, units DESC;
