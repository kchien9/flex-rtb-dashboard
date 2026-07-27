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
-- DO NOT hand-recompute BP boundaries with DATE_TRUNC for month/quarter -- they don't align
-- to calendar boundaries and will drift wrong. The bp_periods CTE below has hardcoded
-- boundaries for illustration only (accurate as of 2026-07-27) -- before this ships, replace
-- it with a real join to a BP_Calendar reference table/seed mirroring flex-comp-engine's
-- ingestion/config_loader.py bp_calendar (start_date/end_date per BP month label), so period
-- boundaries update automatically every month instead of going stale.

WITH bp_periods AS (
    -- PLACEHOLDER -- replace with a real BP_Calendar lookup before shipping, see note above
    SELECT 'this_month'   AS period, DATE '2026-07-05' AS start_date, DATE '2026-08-04' AS end_date
    UNION ALL SELECT 'last_month',   DATE '2026-06-05', DATE '2026-07-04'
    UNION ALL SELECT 'this_quarter', DATE '2026-06-05', DATE '2026-08-04'
    UNION ALL SELECT 'last_quarter', DATE '2026-03-05', DATE '2026-06-04'
    UNION ALL SELECT 'this_week',    DATE_TRUNC('week', CURRENT_DATE()),     CURRENT_DATE()
    UNION ALL SELECT 'last_week',    DATE_TRUNC('week', CURRENT_DATE()) - 7, DATE_TRUNC('week', CURRENT_DATE()) - 1
)
SELECT
    p.period,
    e.TEAM_NAME                                                    AS team,
    o.OPPORTUNITY_TYPE                                             AS deal_type,
    o.PARTNER_MANAGEMENT_SOFTWARE                                  AS msp,
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
{{#Team.value}} WHERE e.TEAM_NAME = '{{Team.value}}' {{/Team.value}}
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2;

-- Companion query: Meetings Completed (same bp_periods pattern, separate table).
-- Renamed from "Tours" -- that was terminology from a prior employer, not a Flex term;
-- Flex calls this "Meetings Completed" everywhere else (SALES_METRICS semantic view, etc).
-- WITH bp_periods AS ( ...same as above... )
-- SELECT
--     p.period,
--     e.TEAM_NAME AS team,
--     COUNT(*) AS meetings_completed
-- FROM bp_periods p
-- JOIN FLEX.SALES.FCT_CRM_MEETING m
--     ON m.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date
-- LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e
--     ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
-- WHERE m.MEETING_TYPE = 'meeting' AND m.MEETING_STATUS = 'completed'
-- {{#Team.value}} AND e.TEAM_NAME = '{{Team.value}}' {{/Team.value}}
-- GROUP BY 1, 2;
