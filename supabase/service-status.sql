-- Service status for [developer] › Admin › Status.
-- The `status` Edge Function checks every service (your website, share pages, sign-in, database, storage,
-- the three server functions, OpenAI, Resend, Datamuse, and the status pages of Supabase, Vercel, GitHub,
-- OpenAI and Apple) and saves one row per service here. A schedule runs it every 5 minutes, so the history
-- builds up even when no app is open. Rows older than 30 days are removed by the function.
--
-- Setup (safe to run again):
--   1. Database › Extensions: turn on pg_cron and pg_net.
--   2. Run this file. It makes a random token in Supabase Vault and schedules the check every 5 minutes.
--   3. Deploy supabase/functions/status as a function named "status". No secrets to add.
--
--   (To stop the schedule:  select cron.unschedule('service-status');)

create table if not exists public.service_checks (
  id      bigserial primary key,
  at      timestamptz not null default now(),
  service text not null,
  ok      text not null check (ok in ('up', 'slow', 'down', 'unknown')),
  ms      int,
  detail  text check (length(detail) <= 300)
);
create index if not exists service_checks_recent on public.service_checks (service, at desc);
alter table public.service_checks enable row level security;
revoke all on public.service_checks from anon, authenticated;

-- For the Admin › Status tab: each service's latest check, uptime over 24 hours and 7 days, and the last
-- 24 hours in 48 half-hour slots (worst result in each slot) for the bar.
create or replace function public.admin_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  perform public._admin_check();
  with latest as (
    select distinct on (service) service, at, ok, ms, detail from public.service_checks
    where at > now() - interval '7 days' order by service, at desc
  ), up as (
    select service,
      round(100.0 * count(*) filter (where ok in ('up', 'slow') and at > now() - interval '24 hours')
            / nullif(count(*) filter (where ok <> 'unknown' and at > now() - interval '24 hours'), 0), 2) as up_24h,
      round(100.0 * count(*) filter (where ok in ('up', 'slow'))
            / nullif(count(*) filter (where ok <> 'unknown'), 0), 2) as up_7d,
      round(avg(ms) filter (where ok in ('up', 'slow') and at > now() - interval '24 hours'))::int as avg_ms_24h,
      max(at) filter (where ok = 'down') as last_down
    from public.service_checks where at > now() - interval '7 days' group by service
  ), slots as (
    select service, s.i,
      (select case when bool_or(c.ok = 'down') then 'down' when bool_or(c.ok = 'slow') then 'slow'
                   when bool_or(c.ok = 'up') then 'up' when count(*) > 0 then 'unknown' else null end
         from public.service_checks c
        where c.service = l.service
          and c.at >  now() - make_interval(mins => (48 - s.i) * 30)
          and c.at <= now() - make_interval(mins => (47 - s.i) * 30)) as st
    from latest l cross join generate_series(0, 47) s(i)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'service', l.service, 'at', l.at, 'ok', l.ok, 'ms', l.ms, 'detail', l.detail,
      'up_24h', u.up_24h, 'up_7d', u.up_7d, 'avg_ms', u.avg_ms_24h, 'last_down', u.last_down,
      'bars', (select jsonb_agg(st order by i) from slots where slots.service = l.service))), '[]'::jsonb)
    into r
  from latest l left join up u on u.service = l.service;
  return jsonb_build_object('services', r, 'checked_at', (select max(at) from public.service_checks));
end $$;

revoke execute on function public.admin_status() from public, anon;
grant execute on function public.admin_status() to authenticated;

-- The schedule's password: a random token kept in Supabase Vault. The status function reads it with the
-- service role key and only runs for a request carrying it (or for a signed-in admin).
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'status_cron_token') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'status_cron_token', 'Lets the 5-minute schedule run the status function');
  end if;
end $$;

create or replace function public._status_cron_token() returns text
language sql stable security definer set search_path = public as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'status_cron_token' limit 1
$$;
revoke execute on function public._status_cron_token() from public, anon, authenticated;
grant execute on function public._status_cron_token() to service_role;

-- Every 5 minutes (needs pg_cron and pg_net). The anon key is public (it's in the app); the token is what lets it in.
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') and exists (select 1 from pg_extension where extname = 'pg_net') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'service-status';
    perform cron.schedule('service-status', '*/5 * * * *', $job$
      select net.http_post(
        url := 'https://cygfgurzvmbtcegkpnss.supabase.co/functions/v1/status',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN5Z2ZndXJ6dm1idGNlZ2twbnNzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE2ODk0MTIsImV4cCI6MjEwNzI2NTQxMn0.kJhE1V8V_W1BIuu0iSVaLqa5GyxeOrUy0lrqylq4_Cs',
          'x-cron-token', (select decrypted_secret from vault.decrypted_secrets where name = 'status_cron_token' limit 1)),
        body := '{"action":"cron"}'::jsonb,
        timeout_milliseconds := 30000)
    $job$);
  else
    raise notice 'Turn on pg_cron and pg_net (Database › Extensions), then run this file again to start the 5-minute schedule.';
  end if;
end $$;

-- make the API see the new functions straight away
notify pgrst, 'reload schema';
