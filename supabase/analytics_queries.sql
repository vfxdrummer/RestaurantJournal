-- Restaurant Journal — analytics queries
-- Paste any of these into Supabase → SQL Editor:
--   https://supabase.com/dashboard/project/djjrmnpqyywploerecpr/sql/new
--
-- Events that fire in the App Store (Release) build:
--   app_open, onboarding_completed, scan_completed, visit_created, visit_viewed,
--   rating_set, map_opened, loyalty_join_tapped
-- (signed_in/out, card_connected, ask_used are dev-only — accounts/cards/Ask are gated out.)
-- Every event also carries: install_id, session (props->>'session'), authenticated, app_version.


-- === SCAN SUCCESS: photos scanned → visits added ===
select
  count(*)                                              as scans,
  sum((props->>'photos_scanned')::int)                 as photos_scanned,
  sum((props->>'visits_added')::int)                   as visits_added,
  round(100.0 * sum((props->>'visits_added')::int)
        / nullif(sum((props->>'photos_scanned')::int), 0), 2) as visits_per_100_photos
from events
where name = 'scan_completed';


-- === VISITS PER BRAND (chains vs "Independent") ===
select props->>'brand' as brand, count(*) as visits
from events
where name = 'visit_created'
group by 1
order by visits desc;


-- === SESSIONS PER DAY (opens + unique installs) ===
select
  date_trunc('day', created_at)::date as day,
  count(*)                            as opens,
  count(distinct install_id)          as unique_installs,
  count(distinct props->>'session')   as sessions
from events
where name = 'app_open'
group by 1
order by 1 desc;


-- === LOCATIONS VIEWED PER SESSION ===
select round(avg(views), 2) as avg_visits_viewed_per_session
from (
  select props->>'session' as session, count(*) as views
  from events
  where name = 'visit_viewed'
  group by 1
) t;


-- === ONBOARDING / ACTIVATION FUNNEL ===
select
  count(distinct install_id) filter (where name = 'app_open')             as installs,
  count(distinct install_id) filter (where name = 'onboarding_completed') as onboarded,
  count(distinct install_id) filter (where name = 'scan_completed')       as scanned,
  count(distinct install_id) filter (where name = 'visit_created')        as got_a_visit;


-- === RATINGS BREAKDOWN ===
select props->>'rating' as rating, count(*) from events
where name = 'rating_set' group by 1 order by 2 desc;


-- === LOYALTY "JOIN" TAPS BY BRAND ===
select props->>'brand' as brand, count(*) from events
where name = 'loyalty_join_tapped' group by 1 order by 2 desc;
