-- Admin tools for [developer] (the Mac dev app): user counts, a searchable user list, error reports and settings.
-- Every function checks public.is_admin() (beta-access.sql: dev@hellodemo.app), so nobody else can call them.
-- Tables that haven't been set up yet are skipped rather than breaking the dashboard.
-- Run after beta-access.sql. Safe to run again.

create or replace function public._admin_check() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
end $$;

-- Is a table there yet? (lets the dashboard work before every SQL file has been run)
create or replace function public._has(t text) returns boolean
language sql stable as $$ select to_regclass(t) is not null $$;

-- ---------- Overview: the numbers at the top of the Admin sheet ----------
create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = public, auth, storage as $$
declare
  o jsonb := '{}'::jsonb; n bigint; j jsonb;
  day_adl timestamptz := date_trunc('day', now() at time zone 'Australia/Adelaide') at time zone 'Australia/Adelaide';
begin
  perform public._admin_check();
  select jsonb_build_object(
    'users', count(*),
    'new_today', count(*) filter (where created_at >= day_adl),
    'new_7d', count(*) filter (where created_at > now() - interval '7 days'),
    'new_30d', count(*) filter (where created_at > now() - interval '30 days'),
    'active_24h', count(*) filter (where last_sign_in_at > now() - interval '24 hours'),
    'active_7d', count(*) filter (where last_sign_in_at > now() - interval '7 days'),
    'google', count(*) filter (where raw_app_meta_data->>'provider' = 'google'),
    'apple', count(*) filter (where raw_app_meta_data->>'provider' = 'apple'))
  into o from auth.users;

  if public._has('public.cloud_library') then
    execute $q$ select jsonb_build_object(
      'songs', coalesce(sum(case when jsonb_typeof(data->'songs') = 'array' then jsonb_array_length(data->'songs') else 0 end), 0),
      'ideas', coalesce(sum(case when jsonb_typeof(data->'ideas') = 'array' then jsonb_array_length(data->'ideas') else 0 end), 0),
      'active_libraries_7d', count(*) filter (where updated_at > now() - interval '7 days'))
      from public.cloud_library $q$ into j;
    o := o || j;
  end if;
  if public._has('public.shared_songs') then execute 'select count(*) from public.shared_songs' into n; o := o || jsonb_build_object('shared_songs', n); end if;
  if public._has('public.shares') then execute 'select count(*) from public.shares' into n; o := o || jsonb_build_object('share_links', n); end if;

  select coalesce(sum((metadata->>'size')::bigint), 0) into n from storage.objects where bucket_id in ('song-files', 'shares');
  o := o || jsonb_build_object('storage_bytes', n);
  if public._has('public.storage_limit') then
    execute 'select per_account_mb from public.storage_limit where id = 1' into n; o := o || jsonb_build_object('storage_mb', n);
  end if;

  if public._has('public.ai_calls') then
    execute $q$ select jsonb_build_object(
      'ai_units_today', coalesce(sum(units) filter (where kind = 'ai'), 0),
      'sync_today', coalesce(sum(units) filter (where kind = 'sync'), 0),
      'ai_users_today', count(distinct user_id))
      from public.ai_calls where at >= date_trunc('day', now()) $q$ into j;
    o := o || j;
  end if;
  if public._has('public.app_errors') then
    execute $q$ select jsonb_build_object('errors_24h', count(*), 'error_users_24h', count(distinct user_id))
      from public.app_errors where at > now() - interval '24 hours' $q$ into j;
    o := o || j;
  end if;
  if public._has('public.signup_limit') then
    execute 'select per_day from public.signup_limit where id = 1' into n; o := o || jsonb_build_object('signups_per_day', n);
  end if;
  if public._has('public.beta_requests') then
    execute $q$ select jsonb_build_object(
      'beta_pending', count(*) filter (where status = 'pending'),
      'beta_approved', count(*) filter (where status = 'approved'),
      'beta_declined', count(*) filter (where status = 'declined'))
      from public.beta_requests $q$ into j;
    o := o || j || jsonb_build_object('gate', coalesce((select gate from public.beta_config where id = 1), false));
  end if;
  return o || jsonb_build_object('at', now());
end $$;

-- ---------- Users: newest first, or matching a search (email, username or name) ----------
create or replace function public.admin_users(p_q text default '', p_limit int default 100) returns jsonb
language plpgsql volatile security definer set search_path = public, auth, storage as $$
declare q text := '%' || lower(coalesce(trim(p_q), '')) || '%'; r jsonb := '[]'::jsonb; gate boolean := false;
begin
  perform public._admin_check();
  if public._has('public.beta_config') then execute 'select coalesce(gate, false) from public.beta_config where id = 1' into gate; end if;
  create temp table if not exists _au (id uuid, email text, provider text, created_at timestamptz, last_sign_in_at timestamptz,
    username text, display_name text, songs int, ideas int, storage_bytes bigint, ai_today int, errors_7d int, beta text) on commit drop;  -- new and empty for each request
  insert into _au (id, email, provider, created_at, last_sign_in_at, storage_bytes)
  select u.id, u.email, u.raw_app_meta_data->>'provider', u.created_at, u.last_sign_in_at,
    (select coalesce(sum((o.metadata->>'size')::bigint), 0) from storage.objects o
      where o.bucket_id in ('song-files', 'shares') and (storage.foldername(o.name))[1] = u.id::text)
  from auth.users u
  order by u.created_at desc;
  if public._has('public.profiles') then
    execute 'update _au a set username = p.username, display_name = p.display_name from public.profiles p where p.user_id = a.id';
  end if;
  if public._has('public.cloud_library') then
    execute $q$ update _au a set
      songs = case when jsonb_typeof(c.data->'songs') = 'array' then jsonb_array_length(c.data->'songs') else 0 end,
      ideas = case when jsonb_typeof(c.data->'ideas') = 'array' then jsonb_array_length(c.data->'ideas') else 0 end
      from public.cloud_library c where c.user_id = a.id $q$;
  end if;
  if public._has('public.ai_calls') then
    execute $q$ update _au a set ai_today = s.n from (select user_id, sum(units)::int n from public.ai_calls
      where kind = 'ai' and at >= date_trunc('day', now()) group by user_id) s where s.user_id = a.id $q$;
  end if;
  if public._has('public.app_errors') then
    execute $q$ update _au a set errors_7d = s.n from (select user_id, count(*)::int n from public.app_errors
      where at > now() - interval '7 days' group by user_id) s where s.user_id = a.id $q$;
  end if;
  if public._has('public.beta_requests') then
    execute $q$ update _au a set beta = b.status from public.beta_requests b
      where b.user_id = a.id or b.email = lower(a.email) $q$;
  end if;
  update _au set beta = 'admin' where lower(email) in (select email from public.app_admins);
  update _au set beta = case when gate then 'none' else 'open' end where beta is null;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into r
    from (select * from _au
      where q = '%%' or lower(coalesce(email, '')) like q or lower(coalesce(username, '')) like q or lower(coalesce(display_name, '')) like q
      order by created_at desc limit greatest(1, least(coalesce(p_limit, 100), 500))) x;
  return r;
end $$;

-- ---------- Error reports: grouped by message, plus the latest ones ----------
create or replace function public.admin_errors(p_hours int default 24) returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare g jsonb := '[]'::jsonb; l jsonb := '[]'::jsonb; since timestamptz := now() - make_interval(hours => greatest(1, least(coalesce(p_hours, 24), 24 * 90)));
begin
  perform public._admin_check();
  if not public._has('public.app_errors') then return jsonb_build_object('groups', g, 'latest', l, 'missing', true); end if;
  execute $q$ select coalesce(jsonb_agg(x order by x.n desc, x.last_at desc), '[]'::jsonb) from (
      select left(message, 300) as message, kind, count(*) as n, count(distinct user_id) as users, max(at) as last_at,
        (array_agg(distinct build))[1:4] as builds, (array_agg(distinct platform))[1:4] as platforms, (array_agg(distinct screen))[1:4] as screens,
        (array_agg(detail order by at desc))[1] as detail
      from public.app_errors where at > $1 group by left(message, 300), kind order by count(*) desc limit 60) x $q$
    into g using since;
  execute $q$ select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) from (
      select e.at, e.build, e.platform, e.kind, e.screen, left(e.message, 300) as message, u.email
      from public.app_errors e left join auth.users u on u.id = e.user_id
      where e.at > $1 order by e.at desc limit 40) x $q$
    into l using since;
  return jsonb_build_object('groups', g, 'latest', l);
end $$;

-- ---------- Errors for one person ----------
create or replace function public.admin_user_errors(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l jsonb := '[]'::jsonb;
begin
  perform public._admin_check();
  if not public._has('public.app_errors') then return l; end if;
  execute $q$ select coalesce(jsonb_agg(x order by x.at desc), '[]'::jsonb) from (
    select at, build, platform, kind, screen, left(message, 300) as message from public.app_errors
    where user_id = $1 order by at desc limit 30) x $q$ into l using p_user;
  return l;
end $$;

-- ---------- Settings: new accounts per day, storage per account ----------
-- p_value null means "no limit".
create or replace function public.admin_set_setting(p_key text, p_value int) returns int
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._admin_check();
  if p_value is not null and p_value < 0 then raise exception 'Use 0 or more, or leave it empty for no limit.'; end if;
  if p_key = 'signups_per_day' then
    if not public._has('public.signup_limit') then raise exception 'Run supabase/signup-limit.sql first.'; end if;
    execute 'update public.signup_limit set per_day = $1 where id = 1' using p_value;
  elsif p_key = 'storage_mb' then
    if not public._has('public.storage_limit') then raise exception 'Run supabase/storage-limit.sql first.'; end if;
    execute 'update public.storage_limit set per_account_mb = $1 where id = 1' using p_value;
  else
    raise exception 'Unknown setting %', p_key;
  end if;
  return p_value;
end $$;

-- ---------- One person: reset today's AI use; give or remove beta access (no email sent) ----------
create or replace function public.admin_reset_ai(p_user uuid) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._admin_check();
  if public._has('public.ai_calls') then execute 'delete from public.ai_calls where user_id = $1 and at >= date_trunc(''day'', now())' using p_user; end if;
end $$;

create or replace function public.admin_set_access(p_user uuid, p_approved boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, auth as $$
declare em text; nm text; rid uuid; res jsonb;
begin
  perform public._admin_check();
  select lower(email), coalesce(raw_user_meta_data->>'full_name', raw_user_meta_data->>'name') into em, nm from auth.users where id = p_user;
  if em is null then raise exception 'That account has no email address.'; end if;
  select id into rid from public.beta_requests where user_id = p_user or email = em order by (user_id = p_user) desc limit 1;
  if rid is null then
    insert into public.beta_requests (email, name, status, user_id) values (em, left(nm, 100), 'pending', p_user) returning id into rid;
  else
    update public.beta_requests set user_id = p_user where id = rid;
  end if;
  res := public.beta_admin_decide(rid, p_approved);
  return res;
end $$;

revoke execute on function public._admin_check(), public.admin_overview(), public.admin_users(text, int), public.admin_errors(int),
  public.admin_user_errors(uuid), public.admin_set_setting(text, int), public.admin_reset_ai(uuid), public.admin_set_access(uuid, boolean) from public, anon;
grant execute on function public._admin_check(), public.admin_overview(), public.admin_users(text, int), public.admin_errors(int),
  public.admin_user_errors(uuid), public.admin_set_setting(text, int), public.admin_reset_ai(uuid), public.admin_set_access(uuid, boolean) to authenticated;
