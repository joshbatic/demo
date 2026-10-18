-- Daily cap on new accounts (for TestFlight).
-- Runs as a Supabase "Before User Created" auth hook, so it applies to every way of signing up.
-- People who already have an account can always sign in; only brand-new accounts count.
--
-- After running this file:
--   Authentication › Hooks › Add hook › "Before User Created" › Postgres › public.hook_signup_limit › Create
--
-- Change the number any time in Table Editor › signup_limit (or run the update at the bottom):
--   per_day = 25   → up to 25 new accounts per day (the day resets at midnight Adelaide time)
--   per_day = 0    → pause all new sign-ups
--   per_day = null → no limit
-- Safe to run again.

create table if not exists public.signup_limit (
  id int primary key default 1 check (id = 1),
  per_day int default 25 check (per_day is null or per_day >= 0)
);
insert into public.signup_limit (id, per_day) values (1, 25) on conflict (id) do nothing;

-- Not readable or writable from the app.
alter table public.signup_limit enable row level security;
revoke all on public.signup_limit from anon, authenticated;

create or replace function public.hook_signup_limit(event jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cap int;
  day_start timestamptz := date_trunc('day', now() at time zone 'Australia/Adelaide') at time zone 'Australia/Adelaide';
  n int;
begin
  select per_day into cap from public.signup_limit where id = 1;
  if cap is null then
    return '{}'::jsonb;
  end if;

  select count(*) into n from auth.users where created_at >= day_start;

  if n >= cap then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 403,
      'message', case when cap = 0
        then 'New sign-ups are paused for now. Please try again later.'
        else 'Today''s tester spots are full. Please try again tomorrow.' end));
  end if;

  return '{}'::jsonb;
end;
$$;

revoke execute on function public.hook_signup_limit(jsonb) from public, anon, authenticated;
grant execute on function public.hook_signup_limit(jsonb) to supabase_auth_admin;

-- update public.signup_limit set per_day = 50 where id = 1;
