-- Performance Cube — meetings, pipeline, closed-won, closed-lost by period
-- Feeds the daily/weekly Performance page. Built on NEW FLEX.* tables (replatform-ready).
-- {{ }} blocks are Superblocks Mustache bindings — Team.value is a filter dropdown component.

WITH periods AS (
    SELECT 'Last Week' AS period,
           DATE_TRUNC('week', CURRENT_DATE()) - 7 AS start_date,
           DATE_TRUNC('week', CURRENT_DATE()) - 1 AS end_date
    UNION ALL
    SELECT 'This Week', DATE_TRUNC('week', CURRENT_DATE()), CURRENT_DATE()
    UNION ALL
    SELECT 'MTD', DATE_TRUNC('month', CURRENT_DATE()), CURRENT_DATE()
    UNION ALL
    SELECT 'QTD', DATE_TRUNC('quarter', CURRENT_DATE()), CURRENT_DATE()
)
SELECT
    p.period,
    e.TEAM_NAME                                                    AS team,
    o.OPPORTUNITY_TYPE                                             AS deal_type,
    o.PARTNER_MANAGEMENT_SOFTWARE                                  AS msp,
    COUNT(DISTINCT IFF(o.CREATED_AT_UTC BETWEEN p.start_date AND p.end_date,
                       o.OPPORTUNITY_ID, NULL))                    AS pipeline_created,
    COUNT(DISTINCT IFF(o.IS_CLOSED_WON
                       AND o.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date,
                       o.OPPORTUNITY_ID, NULL))                    AS closed_won,
    COUNT(DISTINCT IFF(o.IS_CLOSED AND NOT o.IS_CLOSED_WON
                       AND o.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date,
                       o.OPPORTUNITY_ID, NULL))                    AS closed_lost
FROM periods p
JOIN FLEX.SALES.FCT_CRM_OPPORTUNITY o ON TRUE
LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e
    ON o.OWNER_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
{{#Team.value}} WHERE e.TEAM_NAME = '{{Team.value}}' {{/Team.value}}
GROUP BY 1, 2, 3, 4
ORDER BY 1, 2;

-- Companion query: Meetings Completed (same periods pattern, separate table)
-- WITH periods AS ( ...same as above... )
-- SELECT
--     p.period,
--     e.TEAM_NAME AS team,
--     COUNT(*) AS meetings_completed
-- FROM periods p
-- JOIN FLEX.SALES.FCT_CRM_MEETING m
--     ON m.STARTED_AT_UTC BETWEEN p.start_date AND p.end_date
-- LEFT JOIN FLEX.MART.DIM_EMPLOYEE_HISTORY e
--     ON m.EMPLOYEE_SK = e.EMPLOYEE_SK AND e.IS_CURRENT = TRUE
-- WHERE m.MEETING_TYPE = 'meeting' AND m.MEETING_STATUS = 'completed'
-- {{#Team.value}} AND e.TEAM_NAME = '{{Team.value}}' {{/Team.value}}
-- GROUP BY 1, 2;
