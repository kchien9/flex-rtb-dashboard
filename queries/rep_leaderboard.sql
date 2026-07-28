-- Rep Leaderboard -- ranked rep view, on-demand not default. Per Kevin: "hes more mgrs not
-- reps but he should have a view into reps too if he needs to" -- this reverses my earlier
-- caution about conflicting with the "Sham manages managers" principle (see oneonone_prep.sql
-- and insights_stage_velocity.sql headers for that principle elsewhere in this repo). Resolved:
-- it's fine for Sham to HAVE rep-level access, it's just not what should be pushed to him by
-- default -- wire this as a drill-through / separate tab a click away from the team-level
-- views, not a headline panel on the main dashboard.
--
-- Same base and same DSMB exclusion as rolled_out_units_cube.sql (PMC current live unit total
-- <=750, not segment/team). Ranked by new_integrated_units (this period vs last), with team
-- shown so Sham can see who's under which manager without a separate lookup.
--
-- BUG CAUGHT WHILE VALIDATING (2026-07-27): first draft put the last-period conditional SUM
-- inside a WHERE clause that already restricted to only the current BP month -- units_last
-- came back 0 for every single rep, not because it's really zero but because the outer WHERE
-- had already thrown away every row that could have matched. Fixed by widening the WHERE to
-- both months and doing the period split entirely inside the two conditional SUMs.

WITH pmc_size AS (
    SELECT PMC_ID, SUM(PROPERTY_UNIT_COUNT) AS pmc_current_units
    FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS
    WHERE BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
      AND IS_IN_NETWORK
    GROUP BY 1
)
SELECT
    s.HUBSPOT_DEAL_OWNER                                                              AS rep,
    s.HUBSPOT_STATIC_TEAM_NAME_DEAL                                                   AS team,
    SUM(IFF(s.BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
            AND s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0))                       AS units_this,
    SUM(IFF(s.BP_MONTH = DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
            AND s.IS_NEW_INTEGRATED, s.PROPERTY_UNIT_COUNT, 0))                       AS units_last,
    SUM(IFF(s.BP_MONTH = (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS)
            AND (s.IS_RECAPTURED_NEW_ROLLOUT OR s.IS_RECAPTURED_OTHER), s.PROPERTY_UNIT_COUNT, 0)) AS recaptured_units_this
FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS s
LEFT JOIN pmc_size p ON s.PMC_ID = p.PMC_ID
WHERE s.BP_MONTH >= DATEADD(month, -1, (SELECT MAX(BP_MONTH) FROM PRODUCTION.ANALYTICS.PROPERTY_BP_MONTH_STATS))
  AND (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
  AND s.HUBSPOT_DEAL_OWNER IS NOT NULL
  {{#Team.value}} AND s.HUBSPOT_STATIC_TEAM_NAME_DEAL = '{{Team.value}}' {{/Team.value}}
GROUP BY 1, 2
HAVING units_this > 0 OR units_last > 0
ORDER BY units_this DESC;
