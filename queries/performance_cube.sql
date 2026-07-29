-- Performance Cube — meetings, pipeline, closed-won, closed-lost by period
-- Feeds the daily/weekly Performance page. Built on NEW FLEX.* tables (replatform-ready).
--
-- Periods are BP-aligned, not calendar (per Kevin: "everything should be based on BP months
-- not calendar"). BP months don't line up with calendar months -- e.g. as of 2026-07-27 the
-- current BP month is "Aug BP 2026" (Jul 5 -> Aug 4), not calendar July. Using
-- DATE_TRUNC('month', ...) here would silently pull the wrong window.
--
-- Week has no BP definition -- the BP calendar (comp_config_v4.xlsx's BP_Calendar tab) is
-- month-level only -- so This/Last Week stays calendar-week below. Confirm with Sham/data
-- platform whether that's actually right, or whether he wants a BP-aligned week too.
--
-- {{ Granularity.value }} = 'Week' | 'Month' | 'Quarter', a Superblocks toggle component that
-- picks which two rows of bp_periods apply. Once periods are BP-aligned, "This BP Month"
-- already covers what MTD used to mean (elapsed days within the current BP period) -- same
-- for "This BP Quarter" vs QTD -- so those aren't separate columns anymore, just what
-- "This <granularity>" resolves to at the Month/Quarter setting.
--
-- BP boundaries are now SELF-COMPUTING, not hardcoded -- a fixed, verified rule: BP month N
-- spans the 5th of calendar month N-1 through the 4th of calendar month N (e.g. Aug BP 2026 =
-- Jul 5 -> Aug 4), matching flex-comp-engine's BP_Calendar exactly. BP quarters are 3 BP-months
-- wide, grouped the same way DATE_TRUNC('quarter') groups calendar months (Jul/Aug/Sep BP =
-- Q3). No reference table needed -- this formula never goes stale.
--
-- PACING vs. FULL-PERIOD comparison -- Kevin caught this: comparing an elapsed "This Month"
-- (say, 23 days in) against a FULL "Last Month" (~30 days) is apples to oranges -- it reads
-- as "down" almost every day of the month even when pacing is identical, purely because less
-- time has elapsed. Both comparisons are real questions, so both are here, distinctly named:
--   last_month_mtd / last_quarter_qtd -- last period cut off at the SAME elapsed day count as
--     "this" period right now. This is the pacing question: are we ahead or behind at this
--     exact point in the cycle. THIS is the one to compare "this_month" against.
--   last_month_full / last_quarter_full -- the entire prior period. This answers a different
--     question: are we on track to beat last period's total by the time this one closes.
-- Validated live 2026-07-27: this_month = Jul 5 -> Jul 27 (23 days), last_month_mtd = Jun 5 ->
-- Jun 27 (23 days, pacing-matched), last_month_full = Jun 5 -> Jul 4 (30 days, full month).
-- this_quarter = Jun 5 -> Jul 27 (53 days), last_quarter_qtd = Mar 5 -> Apr 26 (53 days,
-- pacing-matched), last_quarter_full = Mar 5 -> Jun 4 (92 days, full quarter).
--
-- WHICH METRICS ACTUALLY GET A PACING %-CHANGE -- resolved with Kevin 2026-07-27, don't
-- relitigate without re-reading this: Meetings Completed gets pacing (this_month vs
-- last_month_mtd) -- AE/SDR activity has a real expected daily/weekly rhythm (SDR call/
-- meeting-booking quotas exist, and the whole SDR -> AE meeting -> pipeline -> closed-won ->
-- units chain is causally connected), so a same-elapsed-day comparison is meaningful.
-- closed_won_units / closed_lost_units do NOT get a pacing %-change -- AEs are held to unit
-- targets, not activity targets, and unlike activity, units have no week-by-week regularity: a
-- single large deal can land at the beginning or end of a BP period essentially arbitrarily,
-- so "day 23 vs day 23" for units is closer to a coin flip than a real signal. Show
-- closed_won_units/closed_lost_units as a running total for the period; last_month_full is
-- still fine to show for context ("on track to beat last month's total"), just never compute
-- a delta against last_month_mtd for these two columns specifically. This is a Superblocks
-- presentation-layer rule as much as a query one -- the query returns all periods' raw
-- numbers regardless; don't wire a pacing-delta widget onto the units columns.
--
-- REFINED 2026-07-29 -- Kevin: "can we add pacing even if deal timing is arbitrary. i feel
-- like its helpful to see how were trending still even if its not linear." This does NOT
-- reverse the rule above -- the banned comparison is specifically this_month vs
-- last_month_mtd (same-elapsed-day, a coin flip for lumpy deals). What Kevin's asking for is
-- simpler and not banned: a plain %-delta between the two numbers ALREADY shown side by side
-- (this_month vs last_month_full, e.g. "254,956 vs 319,419") -- a real, honest, non-projected
-- statement of what already happened, not an extrapolated pace. Show the same arrow+% delta
-- widget on closed_won_units/closed_lost_units (and rolled_out_units_headline.sql's rows) that
-- the activity metrics already show, computed the same way ((this-last_full)/last_full), just
-- keep the caption honest that it can swing hard on one large deal -- don't relabel it
-- "pacing" in the UI copy, since that implies the banned projected version; "vs last [period]"
-- is accurate, "pacing" is not.
-- FILTER ESCAPING -- read before wiring any value filter here: team/rep names contain
-- apostrophes ("Brandon's Team") that break naive '{{Value}}' string interpolation --
-- confirmed live elsewhere in this repo. Prefer Superblocks' native bind-parameter syntax
-- for the Snowflake connector over raw Mustache substitution for every filter below; if only
-- Mustache is available, double the apostrophes in the value before it reaches this query.
--
-- All filterable dimensions (Team, Deal Type, Segment) are included so they can be
-- layered together, not just whichever one is the current row grouping.
-- NO MSP FILTER HERE -- fixed 2026-07-28. PARTNER_MANAGEMENT_SOFTWARE is a dirty
-- deal-grain field (a single opportunity can span properties on different PMS systems,
-- so real rows contain jammed multi-values like "365 Connect;AMC Rent Pay;RealPage" --
-- confirmed live: ~4.8% of populated rows are multi-value, 75 distinct raw values total).
-- This confirms the exact warning already in the README ("use PMS on the rolled-out-units
-- table for MSP slicing instead") -- MSP slicing belongs on rolled_out_units_cube.sql
-- (clean PMS field, 7 real values), never on this deal-grain query.
--
-- DSMB + SEGMENT BUCKET (fixed 2026-07-28 -- this was flagged as an open gap since the
-- start of this repo and left unfixed for too long; Kevin caught it live in Superblocks
-- showing DSMB pods and raw team names instead of the 4 real segments). Same fix as
-- rolled_out_units_cube.sql, adapted to this table's join path:
--   - DSMB exclusion: DIM_CRM_ACCOUNT_HISTORY has both PMC_ID and its own
--     TOTAL_COMPANY_UNITS, but TOTAL_COMPANY_UNITS is the same kind of deal-time snapshot
--     that was already proven unreliable on the old table -- don't use it. Instead join
--     DIM_CRM_ACCOUNT_HISTORY.PMC_ID straight into the SAME pmc_size CTE (current live
--     unit total from PROPERTY_BP_MONTH_STATS) used everywhere else in this repo -- one
--     definition of "is this PMC DSMB-sized," not a second one that can drift out of sync.
--   - segment_bucket: same mapping as rolled_out_units_cube.sql (Brandon's Team -> MM/Ent;
--     Strategic Team / Cory's Team / Heidi's Team -> Strategic; SMB Account Executives
--     (1/2/unnumbered) -> SMB; House Accounts -> House Accounts; NULL -> Not Set;
--     everything else -- DSMB *, Partner Success, SDR pods, leadership-only pods --
--     excluded). Built here off FCT_CRM_OPPORTUNITY.STATIC_TEAM_NAME (deal-grain),
--     validated live to have the same real pod names as the old table. Deliberately NOT
--     built off DIM_EMPLOYEE_HISTORY.TEAM_NAME (rep-grain) -- that field has real data
--     quality problems (duplicate rows per employee, inconsistent labels like "Enterprise
--     AE Manager" instead of a pod name) that STATIC_TEAM_NAME doesn't have.
--   - The Meetings Completed companion query below still groups by DIM_EMPLOYEE_HISTORY.
--     TEAM_NAME (raw pod name, no segment_bucket, no DSMB filter) -- meetings aren't tied
--     to a PMC/account the way deals are, so the DSMB-by-account-size concept doesn't
--     apply the same way. Flagging as a real inconsistency (this page will show 4 clean
--     segments in one section and raw pod names in another) rather than silently leaving
--     it -- fix later if Sham finds the mismatch confusing in practice.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
),
current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
bp_periods AS (
    SELECT 'this_month' AS period,
        DATEADD(day, 4, DATEADD(month, -1, bp_month_label))                                AS start_date,
        LEAST(DATEADD(day, 3, bp_month_label), CURRENT_DATE())                              AS end_date
    FROM current_bp
    UNION ALL
    SELECT 'last_month_full',
        DATEADD(day, 4, DATEADD(month, -2, bp_month_label)),
        DATEADD(day, 3, DATEADD(month, -1, bp_month_label))
    FROM current_bp
    UNION ALL
    SELECT 'last_month_mtd',
        DATEADD(day, 4, DATEADD(month, -2, bp_month_label)),
        DATEADD(day,
            DATEDIFF(day, DATEADD(day,4,DATEADD(month,-1,bp_month_label)), LEAST(DATEADD(day,3,bp_month_label), CURRENT_DATE())),
            DATEADD(day, 4, DATEADD(month, -2, bp_month_label)))
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
    UNION ALL
    SELECT 'last_quarter_qtd',
        DATEADD(day, 4, DATEADD(month, -4, DATE_TRUNC('quarter', bp_month_label))),
        DATEADD(day,
            DATEDIFF(day, DATEADD(day,4,DATEADD(month,-1,DATE_TRUNC('quarter', bp_month_label))),
                          LEAST(DATEADD(day,3,DATEADD(month,2,DATE_TRUNC('quarter', bp_month_label))), CURRENT_DATE())),
            DATEADD(day, 4, DATEADD(month, -4, DATE_TRUNC('quarter', bp_month_label))))
    FROM current_bp
    UNION ALL
    SELECT 'this_week', DATE_TRUNC('week', CURRENT_DATE()), CURRENT_DATE() FROM current_bp
    UNION ALL
    SELECT 'last_week_full', DATE_TRUNC('week', CURRENT_DATE()) - 7, DATE_TRUNC('week', CURRENT_DATE()) - 1 FROM current_bp
    UNION ALL
    -- pacing-matched: last week cut off at the SAME elapsed day count as this_week right
    -- now (e.g. if today is only 1 day into this week, this is just last week's day 1) --
    -- same fix as last_month_mtd/last_quarter_qtd above, applied to week too. This was
    -- missed originally -- caught 2026-07-28 when Kevin asked whether This Week/Last Week
    -- should show side by side; comparing this_week (partial) to last_week_full (all 7
    -- days) has the identical apples-to-oranges problem the month/quarter fix already
    -- solved, just never applied here.
    SELECT 'last_week_wtd',
        DATE_TRUNC('week', CURRENT_DATE()) - 7,
        (DATE_TRUNC('week', CURRENT_DATE()) - 7) + DATEDIFF(day, DATE_TRUNC('week', CURRENT_DATE()), CURRENT_DATE())
    FROM current_bp
),
base AS (
    SELECT
        o.*,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            WHEN o.STATIC_TEAM_NAME = 'House Accounts' THEN 'House Accounts'
            WHEN o.STATIC_TEAM_NAME IS NULL THEN 'Not Set'
            ELSE NULL
        END AS segment_bucket,
        -- team_bucket: NARROWER than segment_bucket, scoped to exactly Sham's 4 units-side
        -- direct-report managers (Brandon/Rory/Sebastian/Dana). House Accounts and Not Set
        -- are valid segment_bucket values but NOT valid team_bucket values -- no manager
        -- owns them. See rolled_out_units_cube.sql's header for the full rationale.
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
            WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
            WHEN o.STATIC_TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
            ELSE NULL
        END AS team_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
)
SELECT
    p.period,
    o.segment_bucket,
    o.team_bucket,
    o.OPPORTUNITY_TYPE                                             AS deal_type,
    COUNT(DISTINCT IFF(o.CREATED_AT_UTC BETWEEN p.start_date AND p.end_date,
                       o.OPPORTUNITY_ID, NULL))                    AS pipeline_created,
    -- unit counts are the primary numbers -- this dashboard is about units, deal counts are
    -- secondary context (how many deals it took to produce that many units)
    COUNT(DISTINCT IFF(o.IS_CLOSED_WON
                       AND o.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date,
                       o.OPPORTUNITY_ID, NULL))                    AS closed_won_deals,
    SUM(IFF(o.IS_CLOSED_WON AND o.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date,
            o.FLEX_UNIT_COUNT, 0))                                 AS closed_won_units,
    COUNT(DISTINCT IFF(o.IS_CLOSED AND NOT o.IS_CLOSED_WON
                       AND o.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date,
                       o.OPPORTUNITY_ID, NULL))                    AS closed_lost_deals,
    SUM(IFF(o.IS_CLOSED AND NOT o.IS_CLOSED_WON AND o.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date,
            o.FLEX_UNIT_COUNT, 0))                                 AS closed_lost_units
FROM bp_periods p
JOIN base o ON TRUE
LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a
    ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
LEFT JOIN pmc_size ps ON a.PMC_ID = ps.PMC_ID
WHERE (ps.pmc_current_units IS NULL OR ps.pmc_current_units > 750)
  AND o.segment_bucket IS NOT NULL
  -- Deal Type scope, confirmed with Kevin 2026-07-28: New Logo, Expansion, Move In only.
  -- Real remaining volume (Uplevel variants, New Vertical, Add On, ILS, Product
  -- Partnership, MSP) is small -- ~46K units / ~3.5% of closed-won volume, trailing 3mo --
  -- excluded from this dashboard's scope, not deleted from the underlying table.
  AND o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
  {{#Team.value}}     AND o.team_bucket = '{{Team.value}}'                    {{/Team.value}}
  {{#DealType.value}}  AND o.OPPORTUNITY_TYPE = '{{DealType.value}}'          {{/DealType.value}}
  {{#Segment.value}}   AND o.segment_bucket = '{{Segment.value}}'             {{/Segment.value}}
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2;

-- Companion query: Meetings Completed (same bp_periods pattern, separate table). THIS is the
-- one metric on this page where a pacing %-change (this_month vs last_month_mtd) is
-- meaningful -- see the note above. Renamed from "Tours" -- that was terminology from a prior
-- employer, not a Flex term; Flex calls this "Meetings Completed" everywhere else
-- (SALES_METRICS semantic view, etc). Validated live 2026-07-27.
-- NOTE: groups by DIM_EMPLOYEE_HISTORY.TEAM_NAME (raw pod name), not segment_bucket -- see
-- header comment above for why (meetings aren't tied to a PMC/account, and the rep-grain
-- team field has real data quality problems the deal-grain field doesn't).
WITH current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
bp_periods AS (
    SELECT 'this_month' AS period,
        DATEADD(day, 4, DATEADD(month, -1, bp_month_label))                                AS start_date,
        LEAST(DATEADD(day, 3, bp_month_label), CURRENT_DATE())                              AS end_date
    FROM current_bp
    UNION ALL
    SELECT 'last_month_mtd',
        DATEADD(day, 4, DATEADD(month, -2, bp_month_label)),
        DATEADD(day,
            DATEDIFF(day, DATEADD(day,4,DATEADD(month,-1,bp_month_label)), LEAST(DATEADD(day,3,bp_month_label), CURRENT_DATE())),
            DATEADD(day, 4, DATEADD(month, -2, bp_month_label)))
    FROM current_bp
    UNION ALL
    SELECT 'this_week', DATE_TRUNC('week', CURRENT_DATE()), CURRENT_DATE() FROM current_bp
    UNION ALL
    SELECT 'last_week_full', DATE_TRUNC('week', CURRENT_DATE()) - 7, DATE_TRUNC('week', CURRENT_DATE()) - 1 FROM current_bp
    UNION ALL
    -- pacing-matched: last week cut off at the SAME elapsed day count as this_week right
    -- now (e.g. if today is only 1 day into this week, this is just last week's day 1) --
    -- same fix as last_month_mtd/last_quarter_qtd above, applied to week too. This was
    -- missed originally -- caught 2026-07-28 when Kevin asked whether This Week/Last Week
    -- should show side by side; comparing this_week (partial) to last_week_full (all 7
    -- days) has the identical apples-to-oranges problem the month/quarter fix already
    -- solved, just never applied here.
    SELECT 'last_week_wtd',
        DATE_TRUNC('week', CURRENT_DATE()) - 7,
        (DATE_TRUNC('week', CURRENT_DATE()) - 7) + DATEDIFF(day, DATE_TRUNC('week', CURRENT_DATE()), CURRENT_DATE())
    FROM current_bp
)
SELECT
    p.period,
    COALESCE(e.TEAM_NAME, 'Not Set') AS team,
    -- same team_bucket mapping as the main query above, so the ONE Team filter component
    -- works consistently across this whole page. CAVEAT (real, not theoretical):
    -- DIM_EMPLOYEE_HISTORY.TEAM_NAME has data quality problems the deal-grain field
    -- doesn't -- confirmed live, Dana Finch shows up under "Enterprise AE Manager" here,
    -- not a clean pod name, so filtering Meetings to "Dana's Team" may undercount her
    -- team's actual meetings. Flagging, not silently fixing -- there's no clean field to
    -- fall back to on the activity side yet.
    CASE
        WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
        WHEN e.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
        WHEN e.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
        WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
        ELSE NULL
    END AS team_bucket,
    COUNT(*) AS meetings_completed
FROM bp_periods p
JOIN FLEX.SALES.FCT_CRM_MEETING m
    ON m.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e
    ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
WHERE m.MEETING_TYPE = 'meeting' AND m.MEETING_STATUS = 'completed'
  {{#Team.value}} AND CASE
        WHEN e.TEAM_NAME = 'Brandon''s Team' THEN 'Brandon''s Team'
        WHEN e.TEAM_NAME = 'SMB Account Executives 1' THEN 'Sebastian''s Team'
        WHEN e.TEAM_NAME = 'SMB Account Executives 2' THEN 'Rory''s Team'
        WHEN e.TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Dana''s Team'
        ELSE NULL
    END = '{{Team.value}}' {{/Team.value}}
GROUP BY 1, 2, 3
ORDER BY 1, 2;
