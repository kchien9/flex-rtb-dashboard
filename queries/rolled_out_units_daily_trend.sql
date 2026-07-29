-- Rolled-Out Units, Daily Trend -- Kevin: "do we not have a table that shows running rolled
-- out units? so we can see change on the daily?" Answer: not yet, this is that table.
--
-- GROSS ADDS ONLY, NOT A TRUE NET -- checked live before building this: there's no day-level
-- deactivation date on PROPERTY_BP_MONTH_STATS, only a BP-month IS_DEACTIVATED flag with no
-- date attached to it. So a true daily "net change" (adds minus deactivations) genuinely can't
-- be built at day grain -- deactivation timing just isn't tracked that precisely. This shows
-- daily GROSS new rollouts (ROLLOUT_DATE) -- real, validated day-level data (see
-- rolled_out_units_headline.sql's header for the discovery) -- and a running cumulative sum of
-- those gross adds WITHIN the lookback window, not a reconstruction of total network stock.
-- Don't bind `cumulative_new_units` to anything that implies "total units in the network" --
-- for that, use rolled_out_units_cube.sql's integrated_total_units (the real stock, BP-month
-- grain). This is "how many NEW units have rolled out since the window started," which is a
-- different, narrower question.
--
-- REAL DATA IS SPIKY, NOT SMOOTH -- validated live: most days show a few thousand units from
-- a few hundred properties, but 2026-07-24 alone shows 36,276 units from just 308 properties --
-- a single large portfolio activation, not an anomaly to smooth over. Some days show zero rows
-- at all (weekends/no activity that day) -- {{ LookbackDays.value }} window should be filled
-- with zero-value days by Superblocks' chart component (not this query) so the daily bar chart
-- doesn't silently skip gaps.
--
-- Same DSMB exclusion, segment_bucket/team_bucket mapping, and filters as
-- rolled_out_units_cube.sql -- stays consistent with every other rolled-out-units view.

WITH pmc_size AS (
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
    WHERE s.IS_NEW_INTEGRATED = TRUE AND s.ROLLOUT_DATE IS NOT NULL
),
daily AS (
    SELECT
        b.ROLLOUT_DATE                     AS day,
        SUM(b.PROPERTY_UNIT_COUNT)          AS new_units,
        COUNT(*)                            AS properties
    FROM base b
    LEFT JOIN pmc_size p ON b.PMC_ID = p.PMC_ID
    WHERE (p.pmc_current_units IS NULL OR p.pmc_current_units > 750)
      AND b.segment_bucket IS NOT NULL
      AND b.ROLLOUT_DATE >= DATEADD(day, -{{ LookbackDays.value }}, CURRENT_DATE())
      {{#Team.value}}     AND b.team_bucket = '{{Team.value}}'       {{/Team.value}}
      {{#Segment.value}}  AND b.segment_bucket = '{{Segment.value}}' {{/Segment.value}}
      {{#Msp.value}}       AND b.PMS = '{{Msp.value}}'                {{/Msp.value}}
      {{#DealType.value}}  AND b.HUBSPOT_DEAL_TYPE = '{{DealType.value}}' {{/DealType.value}}
    GROUP BY 1
)
SELECT
    day,
    new_units,
    properties,
    SUM(new_units) OVER (ORDER BY day) AS cumulative_new_units
FROM daily
ORDER BY day;
