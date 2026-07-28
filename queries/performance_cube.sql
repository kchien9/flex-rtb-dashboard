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
-- FILTER ESCAPING -- read before wiring any value filter here: team/rep names contain
-- apostrophes ("Brandon's Team") that break naive '{{Value}}' string interpolation --
-- confirmed live elsewhere in this repo. Prefer Superblocks' native bind-parameter syntax
-- for the Snowflake connector over raw Mustache substitution for every filter below; if only
-- Mustache is available, double the apostrophes in the value before it reaches this query.
--
-- All filterable dimensions (Team, MSP, Deal Type, Segment) are included so they can be
-- layered together, not just whichever one is the current row grouping.

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
    SELECT 'last_week', DATE_TRUNC('week', CURRENT_DATE()) - 7, DATE_TRUNC('week', CURRENT_DATE()) - 1 FROM current_bp
)
SELECT
    p.period,
    COALESCE(e.TEAM_NAME, 'Not Set')                               AS team,
    COALESCE(o.OPPORTUNITY_TYPE, 'Not Set')                        AS deal_type,
    COALESCE(o.PARTNER_MANAGEMENT_SOFTWARE, 'Not Set')             AS msp,
    COALESCE(a.ACCOUNT_SEGMENT, 'Not Set')                         AS segment,
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
JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON TRUE
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e
    ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
LEFT JOIN FLEX.SALES.DIM_CRM_ACCOUNT_HISTORY a
    ON o.CRM_ACCOUNT_SK = a.CRM_ACCOUNT_SK AND a.IS_CURRENT = TRUE
WHERE 1=1
  {{#Team.value}}     AND e.TEAM_NAME = '{{Team.value}}'                       {{/Team.value}}
  {{#Msp.value}}       AND o.PARTNER_MANAGEMENT_SOFTWARE = '{{Msp.value}}'     {{/Msp.value}}
  {{#DealType.value}}  AND o.OPPORTUNITY_TYPE = '{{DealType.value}}'          {{/DealType.value}}
  {{#Segment.value}}   AND a.ACCOUNT_SEGMENT = '{{Segment.value}}'            {{/Segment.value}}
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1, 2;

-- Companion query: Meetings Completed (same bp_periods pattern, separate table). THIS is the
-- one metric on this page where a pacing %-change (this_month vs last_month_mtd) is
-- meaningful -- see the note above. Renamed from "Tours" -- that was terminology from a prior
-- employer, not a Flex term; Flex calls this "Meetings Completed" everywhere else
-- (SALES_METRICS semantic view, etc). Validated live 2026-07-27.
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
    SELECT 'last_week', DATE_TRUNC('week', CURRENT_DATE()) - 7, DATE_TRUNC('week', CURRENT_DATE()) - 1 FROM current_bp
)
SELECT
    p.period,
    COALESCE(e.TEAM_NAME, 'Not Set') AS team,
    COUNT(*) AS meetings_completed
FROM bp_periods p
JOIN FLEX.SALES.FCT_CRM_MEETING m
    ON m.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e
    ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
WHERE m.MEETING_TYPE = 'meeting' AND m.MEETING_STATUS = 'completed'
  {{#Team.value}} AND e.TEAM_NAME = '{{Team.value}}' {{/Team.value}}
GROUP BY 1, 2
ORDER BY 1, 2;
