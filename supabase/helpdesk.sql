-- *[demo] help desk and admin controls, for [developer] › Admin.
-- Run after beta-access.sql, admin-tools.sql and plans.sql. Safe to run again.
--
--   Help desk       people send a message from Account › Contact Support (through the support function, which
--                   emails you). You read and answer them in Admin › Help; answers are emailed to them and show
--                   in the app.
--   Devices         the app checks in when it opens (device, platform, build), so you can see who's on what.
--   Remote controls an announcement banner, switches to pause AI, lyric sync or uploads, and the oldest build
--                   allowed. The app reads them on launch, and the server enforces the switches.
--   User detail     everything about one account in one place, plus suspend and sign out everywhere.
--
-- Nothing here stores lyrics or song content.

-- ---------- help desk ----------
create table if not exists public.support_tickets (
  id         bigserial primary key,
  user_id    uuid,                                   -- the account (no foreign key, so accounts can still be removed)
  email      text check (length(email) <= 320),
  name       text check (length(name) <= 120),
  topic      text not null default 'other' check (topic in ('bug', 'account', 'billing', 'idea', 'other')),
  message    text not null check (length(message) between 1 and 4000),
  diag       jsonb,                                  -- app build, device and recent errors, if they allowed it
  status     text not null default 'open' check (status in ('open', 'replied', 'closed')),
  replies    jsonb not null default '[]'::jsonb,     -- [{ "at": ..., "by": "admin", "text": ... }]
  note       text check (length(note) <= 2000),      -- your private note
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists support_tickets_status on public.support_tickets (status, created_at desc);
create index if not exists support_tickets_user on public.support_tickets (user_id, created_at desc);
alter table public.support_tickets enable row level security;
revoke all on public.support_tickets from anon, authenticated;

-- the person's own tickets and your replies, for Account › Contact Support
create or replace function public.my_tickets() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'topic', topic, 'message', message, 'status', status,
    'replies', replies, 'created_at', created_at, 'updated_at', updated_at) order by created_at desc), '[]'::jsonb)
  from (select * from public.support_tickets where user_id = auth.uid() order by created_at desc limit 20) t
$$;

create or replace function public.admin_tickets(p_status text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare r jsonb;
begin
  perform public._admin_check();
  select jsonb_build_object(
    'counts', (select jsonb_build_object('open', count(*) filter (where status = 'open'), 'replied', count(*) filter (where status = 'replied'),
                 'closed', count(*) filter (where status = 'closed')) from public.support_tickets),
    'list', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
        select t.*, p.username, p.display_name from public.support_tickets t left join public.profiles p on p.user_id = t.user_id
        where p_status = 'all' or t.status = p_status order by t.created_at desc limit 200) x), '[]'::jsonb))
  into r;
  return r;
end $$;

create or replace function public.admin_ticket_update(p_id bigint, p_status text default null, p_note text default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r jsonb;
begin
  perform public._admin_check();
  update public.support_tickets set
    status = coalesce(p_status, status),
    note = case when p_note is null then note else nullif(left(p_note, 2000), '') end,
    updated_at = now()
  where id = p_id returning to_jsonb(support_tickets.*) into r;
  if r is null then raise exception 'No such ticket'; end if;
  return r;
end $$;

-- ---------- devices: which builds people are on ----------
create table if not exists public.app_seen (
  user_id    uuid not null,
  device     text not null check (length(device) <= 64),
  platform   text check (length(platform) <= 40),
  build      text check (length(build) <= 40),
  seq        int,
  ua         text check (length(ua) <= 300),
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  primary key (user_id, device)
);
alter table public.app_seen enable row level security;
revoke all on public.app_seen from anon, authenticated;

create or replace function public.app_seen_ping(p_device text, p_platform text, p_build text, p_seq int, p_ua text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce(p_device, '') = '' then return; end if;
  insert into public.app_seen (user_id, device, platform, build, seq, ua)
  values (auth.uid(), left(p_device, 64), left(p_platform, 40), left(p_build, 40), p_seq, left(p_ua, 300))
  on conflict (user_id, device) do update set platform = excluded.platform, build = excluded.build, seq = excluded.seq,
    ua = excluded.ua, last_seen = now();
end $$;

-- ---------- remote controls ----------
create table if not exists public.app_config (
  id          int primary key default 1 check (id = 1),
  banner      text check (length(banner) <= 300),      -- shown at the top of the app for everyone; empty = none
  banner_kind text not null default 'info' check (banner_kind in ('info', 'warn')),
  banner_id   text,                                    -- changes whenever the banner does, so a new one shows again
  ai_off      boolean not null default false,          -- pause AI features (Lines, Muse, Rate, writing voice)
  sync_off    boolean not null default false,          -- pause lyric sync
  uploads_off boolean not null default false,          -- pause adding music and files
  min_seq     int not null default 0,                  -- builds older than this see "Update required"
  update_note text check (length(update_note) <= 300),
  updated_at  timestamptz not null default now()
);
insert into public.app_config (id) values (1) on conflict (id) do nothing;
alter table public.app_config enable row level security;
revoke all on public.app_config from anon, authenticated;

-- what every app reads on launch (signed in or not)
create or replace function public.app_config_public() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('banner', nullif(banner, ''), 'banner_kind', banner_kind, 'banner_id', banner_id,
    'ai_off', ai_off, 'sync_off', sync_off, 'uploads_off', uploads_off, 'min_seq', min_seq, 'update_note', update_note,
    'updated_at', updated_at)
  from public.app_config where id = 1
$$;

create or replace function public.admin_set_config(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._admin_check();
  update public.app_config set
    banner      = case when p ? 'banner' then nullif(left(trim(p->>'banner'), 300), '') else banner end,
    banner_kind = case when p ? 'banner_kind' and p->>'banner_kind' in ('info', 'warn') then p->>'banner_kind' else banner_kind end,
    banner_id   = case when p ? 'banner' then md5(coalesce(p->>'banner', '') || now()::text) else banner_id end,
    ai_off      = case when p ? 'ai_off' then (p->>'ai_off')::boolean else ai_off end,
    sync_off    = case when p ? 'sync_off' then (p->>'sync_off')::boolean else sync_off end,
    uploads_off = case when p ? 'uploads_off' then (p->>'uploads_off')::boolean else uploads_off end,
    min_seq     = case when p ? 'min_seq' then greatest(0, (p->>'min_seq')::int) else min_seq end,
    update_note = case when p ? 'update_note' then nullif(left(trim(p->>'update_note'), 300), '') else update_note end,
    updated_at  = now()
  where id = 1;
  return public.app_config_public();
end $$;

-- the switches, for the server's own checks
create or replace function public.feature_off(f text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select case f when 'ai' then ai_off when 'sync' then sync_off when 'uploads' then uploads_off end
                   from public.app_config where id = 1), false)
$$;

-- uploads switch: one more rule on adding files (song files and share-link audio)
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'storage: uploads on') then
    create policy "storage: uploads on" on storage.objects as restrictive for insert to authenticated
      with check (bucket_id not in ('song-files', 'shares') or not public.feature_off('uploads'));
  end if;
end $$;

-- ---------- user detail and account actions ----------
create or replace function public.admin_user_detail(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, auth, storage as $$
declare r jsonb; u record;
begin
  perform public._admin_check();
  select id, email, created_at, last_sign_in_at, banned_until, raw_app_meta_data, raw_user_meta_data into u from auth.users where id = p_user;
  if u.id is null then raise exception 'No such account'; end if;
  r := jsonb_build_object(
    'id', u.id, 'email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at,
    'banned_until', u.banned_until, 'suspended', u.banned_until is not null and u.banned_until > now(),
    'provider', u.raw_app_meta_data->>'provider', 'providers', u.raw_app_meta_data->'providers',
    'meta_name', coalesce(u.raw_user_meta_data->>'full_name', u.raw_user_meta_data->>'name'),
    'admin', exists (select 1 from public.app_admins a where lower(a.email) = lower(u.email)));
  if public._has('public.profiles') then
    r := r || coalesce((select jsonb_build_object('username', username, 'display_name', display_name) from public.profiles where user_id = p_user), '{}'::jsonb);
  end if;
  if to_regprocedure('public.plan_for(uuid)') is not null then
    r := r || jsonb_build_object('plan', public.plan_for(p_user),
      'plan_row', (select to_jsonb(p) - 'user_id' from public.plans p where p.user_id = p_user),
      'storage_limit', public.storage_limit_for(p_user));
  end if;
  r := r || jsonb_build_object('storage_used', (select coalesce(sum((o.metadata->>'size')::bigint), 0) from storage.objects o
    where o.bucket_id in ('song-files', 'shares') and (storage.foldername(o.name))[1] = p_user::text));
  if public._has('public.beta_requests') then
    r := r || jsonb_build_object('beta', (select jsonb_build_object('status', status, 'created_at', created_at, 'decided_at', decided_at)
      from public.beta_requests b where b.user_id = p_user or b.email = lower(u.email) order by created_at desc limit 1));
  end if;
  if public._has('public.cloud_library') then
    r := r || coalesce((select jsonb_build_object(
      'songs', case when jsonb_typeof(data->'songs') = 'array' then jsonb_array_length(data->'songs') else 0 end,
      'ideas', case when jsonb_typeof(data->'ideas') = 'array' then jsonb_array_length(data->'ideas') else 0 end,
      'library_at', updated_at) from public.cloud_library where user_id = p_user), '{}'::jsonb);
  end if;
  if public._has('public.ai_calls') then
    r := r || (select jsonb_build_object(
      'ai_today', coalesce(sum(units) filter (where kind = 'ai' and at >= date_trunc('day', now())), 0),
      'sync_today', coalesce(sum(units) filter (where kind = 'sync' and at >= date_trunc('day', now())), 0),
      'heavy_month', coalesce(sum(units) filter (where kind = 'ai' and units >= 3 and at >= date_trunc('month', now())), 0) / 3,
      'sync_month', coalesce(sum(units) filter (where kind = 'sync' and at >= date_trunc('month', now())), 0),
      'ai_last', max(at)) from public.ai_calls where user_id = p_user);
  end if;
  r := r || jsonb_build_object('devices', coalesce((select jsonb_agg(jsonb_build_object('device', device, 'platform', platform, 'build', build,
      'seq', seq, 'ua', ua, 'first_seen', first_seen, 'last_seen', last_seen) order by last_seen desc) from public.app_seen where user_id = p_user), '[]'::jsonb));
  r := r || jsonb_build_object('sessions', (select jsonb_build_object('active', count(*) filter (where not_after is null or not_after > now()),
      'agents', coalesce(jsonb_agg(distinct left(user_agent, 120)) filter (where (not_after is null or not_after > now()) and user_agent is not null), '[]'::jsonb),
      'last_refresh', max(refreshed_at)) from auth.sessions where user_id = p_user));
  if public._has('public.app_errors') then
    r := r || jsonb_build_object('errors', coalesce((select jsonb_agg(to_jsonb(e) - 'user_id' order by e.at desc) from
      (select * from public.app_errors where user_id = p_user order by at desc limit 15) e), '[]'::jsonb),
      'errors_7d', (select count(*) from public.app_errors where user_id = p_user and at > now() - interval '7 days'));
  end if;
  r := r || jsonb_build_object('tickets', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'topic', topic, 'status', status,
      'message', left(message, 200), 'created_at', created_at) order by created_at desc) from public.support_tickets where user_id = p_user), '[]'::jsonb));
  if public._has('public.shared_songs') then
    r := r || jsonb_build_object('owns_shared', (select count(*) from public.shared_songs where owner_id = p_user));
  end if;
  if public._has('public.collab_members') then
    r := r || jsonb_build_object('member_of', (select count(*) from public.collab_members where user_id = p_user));
  end if;
  if public._has('public.collab_invites') then
    r := r || jsonb_build_object('invites_sent', (select count(*) from public.collab_invites where owner_id = p_user and status = 'pending'),
      'invites_waiting', (select count(*) from public.collab_invites where invitee_user_id = p_user and status = 'pending'));
  end if;
  if public._has('public.shares') then
    r := r || jsonb_build_object('share_links', (select count(*) from public.shares where owner = p_user));
  end if;
  if public._has('public.user_blocks') then
    r := r || jsonb_build_object('blocking', (select count(*) from public.user_blocks where blocker = p_user),
      'blocked_by', (select count(*) from public.user_blocks where blocked = p_user));
  end if;
  return r;
end $$;

-- sign out everywhere: ends every session and refresh token, so each device asks them to sign in again within the hour
create or replace function public.admin_signout_user(p_user uuid) returns int
language plpgsql volatile security definer set search_path = public, auth as $$
declare n int;
begin
  perform public._admin_check();
  update auth.sessions set not_after = now() where user_id = p_user and (not_after is null or not_after > now());
  get diagnostics n = row_count;
  update auth.refresh_tokens set revoked = true, updated_at = now() where user_id = p_user::text and not revoked;
  return n;
end $$;

-- suspend: they can't sign in or stay signed in until you lift it (nothing is removed)
create or replace function public.admin_suspend(p_user uuid, p_on boolean) returns boolean
language plpgsql volatile security definer set search_path = public, auth as $$
declare em text;
begin
  perform public._admin_check();
  select email into em from auth.users where id = p_user;
  if em is null then raise exception 'No such account'; end if;
  if p_on and exists (select 1 from public.app_admins a where lower(a.email) = lower(em)) then raise exception 'Admins can''t be suspended'; end if;
  update auth.users set banned_until = case when p_on then now() + interval '100 years' else null end, updated_at = now() where id = p_user;
  if p_on then
    update auth.sessions set not_after = now() where user_id = p_user and (not_after is null or not_after > now());
    update auth.refresh_tokens set revoked = true, updated_at = now() where user_id = p_user::text and not revoked;
  end if;
  return p_on;
end $$;

-- which builds people are on (last 30 days), for choosing a minimum build in Admin › Settings
create or replace function public.admin_builds() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._admin_check();
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.seq desc nulls last, x.people desc) from (
    select build, platform, max(seq) as seq, count(*) as devices, count(distinct user_id) as people, max(last_seen) as last_seen
    from public.app_seen where last_seen > now() - interval '30 days' group by build, platform) x), '[]'::jsonb);
end $$;

-- ---------- permissions ----------
revoke execute on function public.my_tickets(), public.admin_tickets(text), public.admin_ticket_update(bigint, text, text),
  public.app_seen_ping(text, text, text, int, text), public.app_config_public(), public.admin_set_config(jsonb),
  public.feature_off(text), public.admin_user_detail(uuid), public.admin_signout_user(uuid), public.admin_suspend(uuid, boolean), public.admin_builds() from public;
grant execute on function public.app_config_public() to anon, authenticated;
grant execute on function public.feature_off(text) to authenticated;
grant execute on function public.my_tickets(), public.app_seen_ping(text, text, text, int, text), public.admin_tickets(text),
  public.admin_ticket_update(bigint, text, text), public.admin_set_config(jsonb), public.admin_user_detail(uuid),
  public.admin_signout_user(uuid), public.admin_suspend(uuid, boolean), public.admin_builds() to authenticated;

notify pgrst, 'reload schema';
