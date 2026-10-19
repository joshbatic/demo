-- *[demo] plans: Free and Pro (see the pricing plan in the DEMO project).
-- Run after beta-access.sql, storage-limit.sql, ai-limits.sql and admin-tools.sql. Safe to run again.
--
-- Each person's plan is decided here, on the server, so it can't be changed from the app:
--   'pro'   a paid (or admin-given) subscription, or an admin account
--   'beta'  while "beta unlocks everything" is on, anyone with beta access gets everything (today's behaviour)
--   'free'  everyone else
-- Admins can set anyone to Pro or Free (Admin › Users), and turn "beta unlocks everything" off (Admin › Settings)
-- when payments go live. A 'free' row overrides everything (even admin), so you can test the free experience.
--
-- Limits:            Free                      Beta (as today)        Pro
--   Quick AI          10 a day                  300 a day              300 a day
--   Rate / voice      not included              in the 300             100 a month
--   Lyric sync        not included              60 min a day           60 min a day, 300 min a month
--   File storage      none for songs (memos     storage_limit table    5 GB
--                     stay on the device); 20   (150 MB in the beta)
--                     MB of share-link pictures
--   Inviting          can join, can't invite    yes                    yes
--   Others' audio     can't play shared files   yes                    yes
-- Your own uploads can always be played and downloaded, whatever your plan.

-- ---------- who's on what ----------
create table if not exists public.plans (
  user_id    uuid primary key,                      -- an auth.users id
  tier       text not null check (tier in ('free', 'pro', 'auto')),   -- auto = no override (beta or free)
  source     text not null default 'admin',      -- admin, apple, promo…
  expires_at timestamptz,                         -- null = no end date
  updated_at timestamptz not null default now()
);
alter table public.plans enable row level security;
revoke all on public.plans from anon, authenticated;

create table if not exists public.plan_config (
  id           int primary key default 1 check (id = 1),
  beta_unlocks boolean not null default true
);
insert into public.plan_config (id) values (1) on conflict (id) do nothing;
alter table public.plan_config enable row level security;
revoke all on public.plan_config from anon, authenticated;

create or replace function public.plan_for(p_user uuid) returns text
language sql stable security definer set search_path = public, auth as $$
  select case
    when p_user is null then 'free'
    when exists (select 1 from public.plans p where p.user_id = p_user and p.tier = 'free') then 'free'
    when exists (select 1 from public.app_admins a join auth.users u on lower(u.email) = lower(a.email) where u.id = p_user) then 'pro'
    when exists (select 1 from public.plans p where p.user_id = p_user and p.tier = 'pro' and (p.expires_at is null or p.expires_at > now())) then 'pro'
    when coalesce((select beta_unlocks from public.plan_config where id = 1), true)
     and (not coalesce((select gate from public.beta_config where id = 1), false)
          or exists (select 1 from public.beta_requests r join auth.users u on u.id = p_user
                     where r.status = 'approved' and (r.user_id = p_user or r.email = lower(u.email)))) then 'beta'
    else 'free'
  end
$$;

-- Does the signed-in person get the paid features?
create or replace function public.paid() returns boolean
language sql stable security definer set search_path = public as $$
  select public.plan_for(auth.uid()) <> 'free'
$$;

-- Storage allowed for a plan, in bytes (null = no limit)
create or replace function public.storage_limit_for(p_user uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select case public.plan_for(p_user)
    when 'pro'  then 5120::bigint * 1048576
    when 'beta' then (select per_account_mb::bigint * 1048576 from public.storage_limit where id = 1)
    else 20::bigint * 1048576      -- Free: room for share-link pictures only
  end
$$;

-- For the app: plan, limits and this month's use
create or replace function public.my_plan() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tier', public.plan_for(auth.uid()),
    'expires_at', (select expires_at from public.plans where user_id = auth.uid() and tier = 'pro'),
    'source', (select source from public.plans where user_id = auth.uid()),
    'beta_unlocks', coalesce((select beta_unlocks from public.plan_config where id = 1), true),
    'storage_limit', public.storage_limit_for(auth.uid()),
    'storage_used', public.storage_used(auth.uid()),
    'heavy_month', (select coalesce(sum(units), 0) / 3 from public.ai_calls where user_id = auth.uid() and kind = 'ai' and units >= 3 and at >= date_trunc('month', now())),
    'sync_month', (select coalesce(sum(units), 0) from public.ai_calls where user_id = auth.uid() and kind = 'sync' and at >= date_trunc('month', now())))
$$;

-- ---------- AI and lyric sync limits per plan ----------
create or replace function public.ai_take(kind text, units int default 1)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_variable
declare me uuid := auth.uid(); k text := coalesce(kind, 'ai'); u int := greatest(1, least(coalesce(units, 1), 10));
  tier text; day_limit int; minute_limit int; used int; recent int; month_used int;
begin
  if me is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  if to_regprocedure('public.beta_ok()') is not null then
    if not public.beta_ok() then return jsonb_build_object('ok', false, 'reason', 'beta'); end if;
  end if;
  -- remote controls (helpdesk.sql): AI or lyric sync paused for everyone
  if to_regprocedure('public.feature_off(text)') is not null and public.feature_off(case when k = 'sync' then 'sync' else 'ai' end) then
    return jsonb_build_object('ok', false, 'reason', 'off');
  end if;
  tier := public.plan_for(me);
  -- Free: a taste of the quick AI; Rate, writing voice and lyric sync are Pro
  if tier = 'free' and (k = 'sync' or u >= 3) then return jsonb_build_object('ok', false, 'reason', 'pro'); end if;
  day_limit := case when k = 'sync' then 60 when tier = 'free' then 10 else 300 end;
  minute_limit := case k when 'sync' then 12 else 30 end;
  select coalesce(sum(c.units), 0) into used from public.ai_calls c where c.user_id = me and c.kind = k and c.at >= date_trunc('day', now());
  if used + u > day_limit then return jsonb_build_object('ok', false, 'reason', 'day', 'used', used, 'limit', day_limit, 'tier', tier); end if;
  -- Pro: monthly caps on the expensive things
  if tier = 'pro' then
    if k = 'sync' then
      select coalesce(sum(c.units), 0) into month_used from public.ai_calls c where c.user_id = me and c.kind = 'sync' and c.at >= date_trunc('month', now());
      if month_used + u > 300 then return jsonb_build_object('ok', false, 'reason', 'month', 'limit', 300); end if;
    elsif u >= 3 then
      select coalesce(sum(c.units), 0) / 3 into month_used from public.ai_calls c where c.user_id = me and c.kind = 'ai' and c.units >= 3 and c.at >= date_trunc('month', now());
      if month_used + 1 > 100 then return jsonb_build_object('ok', false, 'reason', 'month', 'limit', 100); end if;
    end if;
  end if;
  select count(*) into recent from public.ai_calls c where c.user_id = me and c.kind = k and c.at > now() - interval '1 minute';
  if recent >= minute_limit then return jsonb_build_object('ok', false, 'reason', 'minute', 'limit', minute_limit); end if;
  insert into public.ai_calls (user_id, kind, units) values (me, k, u);
  -- (rows are kept: the monthly caps need the last month, and old rows are tiny)
  return jsonb_build_object('ok', true, 'used', used + u, 'limit', day_limit, 'tier', tier);
end $$;
revoke all on function public.ai_take(text, int) from public, anon;
grant execute on function public.ai_take(text, int) to authenticated;

-- ---------- file storage per plan ----------
create or replace function public.my_storage() returns table(used_bytes bigint, limit_bytes bigint)
language sql stable security definer set search_path = public as $$
  select public.storage_used(auth.uid()), public.storage_limit_for(auth.uid())
$$;

create or replace function public.storage_has_room() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.storage_used(auth.uid()) < public.storage_limit_for(auth.uid()), true)
$$;

-- (policies are added once, or changed in place, so this file never needs to remove anything)
do $$ begin
  -- Adding files to songs, and audio to share links, needs a paid plan (Free share links can still have their pictures)
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'storage: paid plan') then
    create policy "storage: paid plan" on storage.objects as restrictive for insert to authenticated
      with check (bucket_id not in ('song-files', 'shares') or public.paid()
                  or (bucket_id = 'shares' and lower(storage.extension(name)) in ('png', 'jpg', 'jpeg', 'webp')));
  end if;
  -- Other people's files in a shared song need a paid plan to open; your own uploads always open ("song-files: read own")
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'song-files: read shared') then
    alter policy "song-files: read shared" on storage.objects
      using (bucket_id = 'song-files' and public.paid() and public.can_read_song_file((storage.foldername(name))[1], (storage.foldername(name))[2]));
  else
    create policy "song-files: read shared" on storage.objects for select to authenticated
      using (bucket_id = 'song-files' and public.paid() and public.can_read_song_file((storage.foldername(name))[1], (storage.foldername(name))[2]));
  end if;
  -- Collaboration: Free can join, Pro can invite
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'collab_invites' and policyname = 'invites: paid plan') then
    create policy "invites: paid plan" on public.collab_invites as restrictive for insert to authenticated with check (public.paid());
  end if;
end $$;

-- ---------- admin ----------
create or replace function public.admin_set_plan(p_user uuid, p_tier text, p_days int default null) returns text
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._admin_check();
  if p_tier = 'beta' then p_tier := 'auto'; end if;          -- back to the default (beta or free)
  if p_tier in ('free', 'pro', 'auto') then
    insert into public.plans (user_id, tier, source, expires_at, updated_at)
    values (p_user, p_tier, 'admin', case when p_tier = 'pro' and p_days is not null then now() + make_interval(days => p_days) end, now())
    on conflict (user_id) do update set tier = excluded.tier, source = 'admin', expires_at = excluded.expires_at, updated_at = now();
  else
    raise exception 'Unknown plan %', p_tier;
  end if;
  return public.plan_for(p_user);
end $$;

create or replace function public.admin_set_beta_unlocks(p_on boolean) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._admin_check();
  update public.plan_config set beta_unlocks = p_on where id = 1;
  return p_on;
end $$;

create or replace function public.admin_plan_summary() returns jsonb
language sql stable security definer set search_path = public, auth as $$
  select case when public.is_admin() then jsonb_build_object(
    'pro',  count(*) filter (where t = 'pro'),
    'beta', count(*) filter (where t = 'beta'),
    'free', count(*) filter (where t = 'free'),
    'beta_unlocks', coalesce((select beta_unlocks from public.plan_config where id = 1), true))
  end
  from (select public.plan_for(id) t from auth.users) x
$$;

revoke execute on function public.plan_for(uuid), public.storage_limit_for(uuid) from public, anon, authenticated;
revoke execute on function public.paid(), public.my_plan(), public.my_storage(), public.storage_has_room(),
  public.admin_set_plan(uuid, text, int), public.admin_set_beta_unlocks(boolean), public.admin_plan_summary() from public, anon;
grant execute on function public.paid(), public.my_plan(), public.my_storage(), public.storage_has_room(),
  public.admin_set_plan(uuid, text, int), public.admin_set_beta_unlocks(boolean), public.admin_plan_summary() to authenticated;

notify pgrst, 'reload schema';
