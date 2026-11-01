-- Daily numbers for the [developer] dashboard's trend lines (Accounts, Active today, Pro, Errors today).
-- One row per Adelaide day, kept up to date every hour by pg_cron; admin_trend() returns the last 14 days.
-- Safe to run again. Accounts and errors are back-filled from their own tables; active and Pro start today.
create table if not exists public.admin_daily (
  day     date primary key,
  users   int not null default 0,
  active  int not null default 0,
  pro     int not null default 0,
  errors  int not null default 0,
  at      timestamptz not null default now()
);
alter table public.admin_daily enable row level security;
revoke all on public.admin_daily from anon, authenticated;

create or replace function public.admin_snapshot() returns void
language sql security definer set search_path = public as $$
  insert into public.admin_daily (day, users, active, pro, errors, at)
  select (now() at time zone 'Australia/Adelaide')::date,
    (select count(*) from auth.users),
    (select count(*) from auth.users where last_sign_in_at > now() - interval '24 hours'),
    (select count(*) from public.plans where tier = 'pro' and (expires_at is null or expires_at > now())),
    (select count(*) from public.app_errors where at > now() - interval '24 hours'),
    now()
  on conflict (day) do update set users = excluded.users, active = excluded.active, pro = excluded.pro,
    errors = excluded.errors, at = excluded.at;
$$;
revoke all on function public.admin_snapshot() from public, anon, authenticated;

create or replace function public.admin_trend() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('day', day, 'users', users, 'active', active, 'pro', pro, 'errors', errors) order by day)
    from (select * from public.admin_daily order by day desc limit 14) d), '[]'::jsonb);
end $$;
revoke all on function public.admin_trend() from public, anon;
grant execute on function public.admin_trend() to authenticated;

-- back-fill the last 14 days of accounts and errors
insert into public.admin_daily (day, users, errors)
select d::date,
  (select count(*) from auth.users u where (u.created_at at time zone 'Australia/Adelaide')::date <= d::date),
  (select count(*) from public.app_errors e where (e.at at time zone 'Australia/Adelaide')::date = d::date)
from generate_series((now() at time zone 'Australia/Adelaide')::date - 13, (now() at time zone 'Australia/Adelaide')::date - 1, interval '1 day') d
on conflict (day) do nothing;
select public.admin_snapshot();

select cron.unschedule('admin-snapshot') where exists (select 1 from cron.job where jobname = 'admin-snapshot');
select cron.schedule('admin-snapshot', '7 * * * *', 'select public.admin_snapshot()');
