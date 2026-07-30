-- Pipeline Stage Flow, by Week -- Kevin: "the pipeline charts arent hooked up to the time
-- filters. is that right? the road ahead month forecast shouldnt be hooked up to filters but
-- the pipeline by stage should. id like to see what have moved into each stage by week."
--
-- CONFIRMED both halves of that read are correct, by reading the files directly:
--   - pipeline_forecast.sql filters on the FUTURE expected_month (ANTICIPATED_GO_LIVE_AT_UTC /
--     ROLLOUT_MONTH), controlled only by {{ LookaheadMonths.value }} -- a forward-looking
--     window. There's no historical "look-back" concept for it to hook into; correctly not
--     wired to one.
--   - pipeline_by_stage.sql's bp_periods CTE is hardcoded to exactly TWO fixed windows
--     (this BP month, last full BP month) with no Mustache parameter for period/lookback at
--     all -- there's currently nothing in that query a time filter COULD hook into. Not a bug
--     in that file, just a query built for a fixed this-vs-last comparison rather than an
--     adjustable range.
--
-- This file is the weekly-trend companion pipeline_by_stage.sql's own header already flagged
-- as a natural next addition ("if the point-in-time backlog view turns out to be wanted too,
-- it's a straightforward addition... just not built here since one query per screen"). Same
-- FLOW logic (a deal counts toward a stage in whichever week it ENTERED that stage, via the
-- same QUALIFICATION_AT_UTC/DISCOVERY_AT_UTC/BUILDING_VALUE_AT_UTC/NEGOTIATION_AT_UTC/
-- DEAL_REVIEW_AT_UTC/CLOSED_AT_UTC fields insights_stage_velocity.sql already validated), just
-- bucketed by ISO week (DATE_TRUNC('week', ...), Snowflake default: Monday start) across a
-- trailing {{ WeeksBack.value }} weeks (default 12) instead of two fixed BP-month buckets.
--
-- Output is long/tidy (week_start, segment_bucket, stage, deals, units) -- one row per
-- week x stage (x segment) -- so Superblocks can bind it as a multi-series line/bar chart with
-- one series per stage, matching the "what moved into each stage, over time" framing directly.
--
-- Segment via STATIC_TEAM_NAME, same mapping/reasoning as pipeline_by_stage.sql (deal-grain,
-- reliable on this table). Same OPPORTUNITY_TYPE scope (New Logo / Expansion / Move In).
--
-- Validated live 2026-07-30 against a 2-stage subset (Qualification, Negotiation) before
-- writing the full 6-stage version below -- real per-week, per-segment counts came back
-- correctly bucketed and grouped, no fan-out.

WITH scoped AS (
    SELECT o.*,
        CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            ELSE NULL
        END AS segment_bucket
    FROM FLEX.SALES.FCT_CRM_OPPORTUNITY o
    WHERE o.OPPORTUNITY_TYPE IN ('New Logo', 'Expansion', 'Move In')
      {{#Segment.value}} AND CASE
            WHEN o.STATIC_TEAM_NAME = 'Brandon''s Team' THEN 'MM/Ent'
            WHEN o.STATIC_TEAM_NAME IN ('Strategic Team', 'Cory''s Team', 'Heidi''s Team') THEN 'Strategic'
            WHEN o.STATIC_TEAM_NAME IN ('SMB Account Executives', 'SMB Account Executives 1', 'SMB Account Executives 2') THEN 'SMB'
            ELSE NULL
        END = '{{Segment.value}}' {{/Segment.value}}
),
stage_events AS (
    SELECT segment_bucket, DATE_TRUNC('week', QUALIFICATION_AT_UTC) AS week_start, 'Qualification' AS stage,
        COUNT(DISTINCT OPPORTUNITY_ID) AS deals, SUM(FLEX_UNIT_COUNT) AS units
    FROM scoped
    WHERE segment_bucket IS NOT NULL AND QUALIFICATION_AT_UTC >= DATE_TRUNC('week', DATEADD(week, -{{ WeeksBack.value }}, CURRENT_DATE()))
    GROUP BY 1, 2
    UNION ALL
    SELECT segment_bucket, DATE_TRUNC('week', DISCOVERY_AT_UTC), 'Discovery',
        COUNT(DISTINCT OPPORTUNITY_ID), SUM(FLEX_UNIT_COUNT)
    FROM scoped
    WHERE segment_bucket IS NOT NULL AND DISCOVERY_AT_UTC >= DATE_TRUNC('week', DATEADD(week, -{{ WeeksBack.value }}, CURRENT_DATE()))
    GROUP BY 1, 2
    UNION ALL
    SELECT segment_bucket, DATE_TRUNC('week', BUILDING_VALUE_AT_UTC), 'Building Value',
        COUNT(DISTINCT OPPORTUNITY_ID), SUM(FLEX_UNIT_COUNT)
    FROM scoped
    WHERE segment_bucket IS NOT NULL AND BUILDING_VALUE_AT_UTC >= DATE_TRUNC('week', DATEADD(week, -{{ WeeksBack.value }}, CURRENT_DATE()))
    GROUP BY 1, 2
    UNION ALL
    SELECT segment_bucket, DATE_TRUNC('week', NEGOTIATION_AT_UTC), 'Negotiation',
        COUNT(DISTINCT OPPORTUNITY_ID), SUM(FLEX_UNIT_COUNT)
    FROM scoped
    WHERE segment_bucket IS NOT NULL AND NEGOTIATION_AT_UTC >= DATE_TRUNC('week', DATEADD(week, -{{ WeeksBack.value }}, CURRENT_DATE()))
    GROUP BY 1, 2
    UNION ALL
    SELECT segment_bucket, DATE_TRUNC('week', DEAL_REVIEW_AT_UTC), 'Deal Review',
        COUNT(DISTINCT OPPORTUNITY_ID), SUM(FLEX_UNIT_COUNT)
    FROM scoped
    WHERE segment_bucket IS NOT NULL AND DEAL_REVIEW_AT_UTC >= DATE_TRUNC('week', DATEADD(week, -{{ WeeksBack.value }}, CURRENT_DATE()))
    GROUP BY 1, 2
    UNION ALL
    SELECT segment_bucket, DATE_TRUNC('week', CLOSED_AT_UTC), 'Closed Won',
        COUNT(DISTINCT OPPORTUNITY_ID), SUM(FLEX_UNIT_COUNT)
    FROM scoped
    WHERE segment_bucket IS NOT NULL AND IS_CLOSED_WON
      AND CLOSED_AT_UTC >= DATE_TRUNC('week', DATEADD(week, -{{ WeeksBack.value }}, CURRENT_DATE()))
    GROUP BY 1, 2
)
SELECT * FROM stage_events
ORDER BY week_start,
    segment_bucket,
    CASE stage
        WHEN 'Qualification' THEN 1 WHEN 'Discovery' THEN 2 WHEN 'Building Value' THEN 3
        WHEN 'Negotiation' THEN 4 WHEN 'Deal Review' THEN 5 WHEN 'Closed Won' THEN 6
    END;
