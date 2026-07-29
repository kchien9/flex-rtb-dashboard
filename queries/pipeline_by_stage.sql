-- Pipeline by Stage -- Kevin asked the right design question before asking for the build:
-- "would you rather see current open units/opps in each stage, or which moved into that
-- respective stage this month?" Point-in-time snapshot vs. flow-into-stage. Went with FLOW,
-- reasoning below -- if the point-in-time backlog view turns out to be wanted too, it's a
-- straightforward addition (current open deals grouped by CURRENT_STAGE, no history needed),
-- just not built here since one query per screen, not two competing defaults.
--
-- WHY FLOW, NOT SNAPSHOT -- ties directly to the main-dashboard design principle already
-- established in this repo (docs/superblocks-setup.md's AI Summary section): Sham's driving
-- question is "going well or slipping, and why" -- a TREND question, not a backlog-management
-- one. A big pile of units sitting in Negotiation right now could mean a healthy, fast-moving
-- big pipeline OR a bunch of deals stuck for months -- point-in-time alone can't tell those
-- apart, you'd also need aging/dwell time to interpret it, which is exactly what already exists
-- elsewhere (insights_stage_velocity.sql's Part B, the stuck-deal watch list, and
-- watchlist_large_deals_at_risk.sql) -- that's the right home for point-in-time-plus-aging
-- detail, an AE-manager-level triage tool. FLOW (how many units moved into each stage THIS
-- period) is inherently a rate/momentum question, trendable month over month, and answers
-- "is the funnel accelerating or slowing" directly -- the org-level question this dashboard is
-- for. Don't duplicate the stuck-deal-detail job here; this is the trend companion to it.
--
-- METHOD -- each of QUALIFICATION_AT_UTC/DISCOVERY_AT_UTC/BUILDING_VALUE_AT_UTC/
-- NEGOTIATION_AT_UTC/DEAL_REVIEW_AT_UTC/CLOSED_AT_UTC (closed-won only for the last one) marks
-- the date a deal ENTERED that stage -- same fields insights_stage_velocity.sql already
-- validated. "Entered stage X this period" counts a deal once for X regardless of whether it
-- has since moved further (a deal that raced through Discovery->Negotiation in the same month
-- legitimately counts as having entered both -- that's a real, valid flow event for each
-- stage, not double-counting the same fact twice).
--
-- Segment via STATIC_TEAM_NAME same as insights_stage_velocity.sql (deal-grain, reliable on
-- this table unlike the old table's DSMB-inclusive segment fields -- see that file's header).
-- This-vs-last BP month, same period pattern as everywhere else in this repo.

WITH current_bp AS (
    SELECT IFF(DAY(CURRENT_DATE()) <= 4,
               DATE_TRUNC('month', CURRENT_DATE()),
               DATE_TRUNC('month', DATEADD(month, 1, CURRENT_DATE()))) AS bp_month_label
),
bp_periods AS (
    SELECT 'this_month' AS period,
        DATEADD(day, 4, DATEADD(month, -1, bp_month_label)) AS start_date,
        LEAST(DATEADD(day, 3, bp_month_label), CURRENT_DATE()) AS end_date
    FROM current_bp
    UNION ALL
    SELECT 'last_month_full',
        DATEADD(day, 4, DATEADD(month, -2, bp_month_label)),
        DATEADD(day, 3, DATEADD(month, -1, bp_month_label))
    FROM current_bp
),
scoped AS (
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
    SELECT segment_bucket, period, stage, deals, units FROM (
        SELECT s.segment_bucket, p.period, 'Qualification' AS stage,
            COUNT(DISTINCT IFF(s.QUALIFICATION_AT_UTC BETWEEN p.start_date AND p.end_date, s.OPPORTUNITY_ID, NULL)) AS deals,
            SUM(IFF(s.QUALIFICATION_AT_UTC BETWEEN p.start_date AND p.end_date, s.FLEX_UNIT_COUNT, 0)) AS units
        FROM bp_periods p JOIN scoped s ON TRUE WHERE s.segment_bucket IS NOT NULL GROUP BY 1, 2
        UNION ALL
        SELECT s.segment_bucket, p.period, 'Discovery',
            COUNT(DISTINCT IFF(s.DISCOVERY_AT_UTC BETWEEN p.start_date AND p.end_date, s.OPPORTUNITY_ID, NULL)),
            SUM(IFF(s.DISCOVERY_AT_UTC BETWEEN p.start_date AND p.end_date, s.FLEX_UNIT_COUNT, 0))
        FROM bp_periods p JOIN scoped s ON TRUE WHERE s.segment_bucket IS NOT NULL GROUP BY 1, 2
        UNION ALL
        SELECT s.segment_bucket, p.period, 'Building Value',
            COUNT(DISTINCT IFF(s.BUILDING_VALUE_AT_UTC BETWEEN p.start_date AND p.end_date, s.OPPORTUNITY_ID, NULL)),
            SUM(IFF(s.BUILDING_VALUE_AT_UTC BETWEEN p.start_date AND p.end_date, s.FLEX_UNIT_COUNT, 0))
        FROM bp_periods p JOIN scoped s ON TRUE WHERE s.segment_bucket IS NOT NULL GROUP BY 1, 2
        UNION ALL
        SELECT s.segment_bucket, p.period, 'Negotiation',
            COUNT(DISTINCT IFF(s.NEGOTIATION_AT_UTC BETWEEN p.start_date AND p.end_date, s.OPPORTUNITY_ID, NULL)),
            SUM(IFF(s.NEGOTIATION_AT_UTC BETWEEN p.start_date AND p.end_date, s.FLEX_UNIT_COUNT, 0))
        FROM bp_periods p JOIN scoped s ON TRUE WHERE s.segment_bucket IS NOT NULL GROUP BY 1, 2
        UNION ALL
        SELECT s.segment_bucket, p.period, 'Deal Review',
            COUNT(DISTINCT IFF(s.DEAL_REVIEW_AT_UTC BETWEEN p.start_date AND p.end_date, s.OPPORTUNITY_ID, NULL)),
            SUM(IFF(s.DEAL_REVIEW_AT_UTC BETWEEN p.start_date AND p.end_date, s.FLEX_UNIT_COUNT, 0))
        FROM bp_periods p JOIN scoped s ON TRUE WHERE s.segment_bucket IS NOT NULL GROUP BY 1, 2
        UNION ALL
        SELECT s.segment_bucket, p.period, 'Closed Won',
            COUNT(DISTINCT IFF(s.IS_CLOSED_WON AND s.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date, s.OPPORTUNITY_ID, NULL)),
            SUM(IFF(s.IS_CLOSED_WON AND s.CLOSED_AT_UTC BETWEEN p.start_date AND p.end_date, s.FLEX_UNIT_COUNT, 0))
        FROM bp_periods p JOIN scoped s ON TRUE WHERE s.segment_bucket IS NOT NULL GROUP BY 1, 2
    )
)
SELECT * FROM stage_events
ORDER BY segment_bucket,
    CASE stage
        WHEN 'Qualification' THEN 1 WHEN 'Discovery' THEN 2 WHEN 'Building Value' THEN 3
        WHEN 'Negotiation' THEN 4 WHEN 'Deal Review' THEN 5 WHEN 'Closed Won' THEN 6
    END,
    period;
