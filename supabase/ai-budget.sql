-- *[demo] AI spending limits (security review, 13 Nov 2026).
--
-- On top of the request counts in plans.sql:
--   * Free accounts are tagged "small" so ai-proxy always uses the small model with short prompts and answers.
--   * Every AI call records its real cost (ai-proxy reports the tokens OpenAI used; lyric sync is priced per minute).
--   * Each account has a daily cost budget (one figure for Free, one for Pro and Beta). Admins are exempt.
--   * A daily spend stop for everyone: once the day's total passes ai_budget_day, AI pauses (ai_off), the admin gets
--     a push notification, and it switches itself back on at midnight UTC.
-- The figures live in app_config (ai_budget_day, ai_user_day_free, ai_user_day_pro), set in the database, not here.
-- A null figure means no limit.

alter table public.ai_calls add column if not exists cost numeric(10,5) not null default 0;
alter table public.ai_calls add column if not exists model text;
alter table public.ai_calls add column if not exists tokens_in int;
alter table public.ai_calls add column if not exists tokens_out int;
create index if not exists ai_calls_at_idx on public.ai_calls (at);

alter table public.app_config add column if not exists ai_budget_day numeric(10,2);
alter table public.app_config add column if not exists ai_user_day_free numeric(10,3);
alter table public.app_config add column if not exists ai_user_day_pro numeric(10,3);
alter table public.app_config add column if not exists ai_auto_off_at timestamptz;

create or replace function public.ai_take(kind text, units integer default 1)
returns jsonb language plpgsql security definer set search_path = public as $$
#variable_conflict use_variable
declare me uuid := auth.uid(); k text := coalesce(kind, 'ai'); u int := greatest(1, least(coalesce(units, 1), 10));
  tier text; day_limit int; minute_limit int; used int; recent int; month_used int;
  cfg record; spent numeric; my_spent numeric; my_cap numeric; adm boolean; rid bigint;
begin
  if me is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  if to_regprocedure('public.beta_ok()') is not null then
    if not public.beta_ok() then return jsonb_build_object('ok', false, 'reason', 'beta'); end if;
  end if;
  if to_regprocedure('public.feature_off(text)') is not null and public.feature_off(case when k = 'sync' then 'sync' else 'ai' end) then
    return jsonb_build_object('ok', false, 'reason', 'off');
  end if;
  tier := public.plan_for(me);
  if tier = 'free' and (k = 'sync' or u >= 3) then return jsonb_build_object('ok', false, 'reason', 'pro'); end if;

  -- the daily spend stop for everyone
  select ai_budget_day, ai_user_day_free, ai_user_day_pro into cfg from public.app_config where id = 1;
  -- (skipped once it has fired today and an admin switched AI back on)
  if cfg.ai_budget_day is not null and not coalesce((select ai_auto_off_at >= date_trunc('day', now()) from public.app_config where id = 1), false) then
    select coalesce(sum(c.cost), 0) into spent from public.ai_calls c where c.at >= date_trunc('day', now());
    if spent >= cfg.ai_budget_day then
      update public.app_config set ai_off = true, ai_auto_off_at = now(), updated_at = now()
       where id = 1 and not ai_off;
      if found then
        perform public._notify(a.uid, 'account', 'AI paused',
          'Today''s AI spend passed US$' || cfg.ai_budget_day || ', so AI is paused until midnight UTC. Turn it back on in Admin › Settings.',
          '{}'::jsonb, 'ai-budget:' || to_char(now(), 'YYYY-MM-DD'))
        from (select u2.id as uid from public.app_admins aa join auth.users u2 on lower(u2.email) = lower(aa.email)) a;
      end if;
      return jsonb_build_object('ok', false, 'reason', 'off');
    end if;
  end if;

  -- each account's daily cost budget (admins are exempt)
  adm := public.is_admin();
  my_cap := case when tier = 'free' then cfg.ai_user_day_free else cfg.ai_user_day_pro end;
  if my_cap is not null and not adm then
    select coalesce(sum(c.cost), 0) into my_spent from public.ai_calls c where c.user_id = me and c.at >= date_trunc('day', now());
    if my_spent >= my_cap then return jsonb_build_object('ok', false, 'reason', 'day', 'tier', tier, 'limit', 0); end if;
  end if;

  day_limit := case when k = 'sync' then 60 when tier = 'free' then 10 else 300 end;
  minute_limit := case k when 'sync' then 12 else 30 end;
  select coalesce(sum(c.units), 0) into used from public.ai_calls c where c.user_id = me and c.kind = k and c.at >= date_trunc('day', now());
  if used + u > day_limit then return jsonb_build_object('ok', false, 'reason', 'day', 'used', used, 'limit', day_limit, 'tier', tier); end if;
  if tier <> 'free' then
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
  -- lyric sync is Whisper, priced per minute (each unit is one minute of audio)
  insert into public.ai_calls (user_id, kind, units, cost, model)
  values (me, k, u, case when k = 'sync' then 0.006 * u else 0 end, case when k = 'sync' then 'whisper-1' end)
  returning id into rid;
  return jsonb_build_object('ok', true, 'used', used + u, 'limit', day_limit, 'tier', tier, 'id', rid, 'small', tier = 'free');
end $$;

-- ai-proxy reports what a call actually used (service role only)
create or replace function public.ai_cost(p_id bigint, p_model text, p_in int, p_out int)
returns void language plpgsql security definer set search_path = public as $$
declare pin numeric; pout numeric;
begin
  -- US$ per million tokens; anything unknown is priced like gpt-5 so it's never undercounted
  select x.i, x.o into pin, pout from (values ('gpt-5-mini', 0.25, 2.0), ('gpt-5-nano', 0.05, 0.4)) as x(m, i, o)
   where p_model like x.m || '%' order by length(x.m) desc limit 1;
  if pin is null then pin := 1.25; pout := 10.0; end if;
  update public.ai_calls set model = left(p_model, 60), tokens_in = greatest(p_in, 0), tokens_out = greatest(p_out, 0),
         cost = round((greatest(p_in, 0) * pin + greatest(p_out, 0) * pout) / 1e6, 5)
   where id = p_id;
end $$;
revoke all on function public.ai_cost(bigint, text, int, int) from public, anon, authenticated;
grant execute on function public.ai_cost(bigint, text, int, int) to service_role;

-- the spend stop switches itself back on at midnight UTC (only if it was the one that switched AI off)
create or replace function public.ai_auto_resume()
returns void language sql security definer set search_path = public as $$
  update public.app_config set ai_off = false, ai_auto_off_at = null, updated_at = now() where id = 1 and ai_auto_off_at is not null;
$$;
revoke all on function public.ai_auto_resume() from public, anon, authenticated;
select cron.schedule('ai-auto-resume', '1 0 * * *', 'select public.ai_auto_resume()');

-- lyric-sync reports how long the audio really was: one unit per started minute, Whisper's price per minute
create or replace function public.ai_charge(p_id bigint, p_units int, p_cost numeric, p_model text)
returns void language sql security definer set search_path = public as $$
  update public.ai_calls set units = greatest(units, least(coalesce(p_units, units), 60)), cost = greatest(coalesce(p_cost, 0), 0), model = left(p_model, 60)
   where id = p_id;
$$;
revoke all on function public.ai_charge(bigint, int, numeric, text) from public, anon, authenticated;
grant execute on function public.ai_charge(bigint, int, numeric, text) to service_role;

-- Admin › Settings: switching AI off by hand keeps it off (no midnight resume); switching it back on after the spend
-- stop keeps the marker, so the stop doesn't fire again that day.
create or replace function public.admin_set_config(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $function$
begin
  perform public._admin_check();
  update public.app_config set
    banner      = case when p ? 'banner' then nullif(left(trim(p->>'banner'), 300), '') else banner end,
    banner_kind = case when p ? 'banner_kind' and p->>'banner_kind' in ('info', 'warn') then p->>'banner_kind' else banner_kind end,
    banner_id   = case when p ? 'banner' then md5(coalesce(p->>'banner', '') || now()::text) else banner_id end,
    ai_off      = case when p ? 'ai_off' then (p->>'ai_off')::boolean else ai_off end,
    ai_auto_off_at = case when p ? 'ai_off' and (p->>'ai_off')::boolean then null else ai_auto_off_at end,
    sync_off    = case when p ? 'sync_off' then (p->>'sync_off')::boolean else sync_off end,
    uploads_off = case when p ? 'uploads_off' then (p->>'uploads_off')::boolean else uploads_off end,
    min_seq     = case when p ? 'min_seq' then greatest(0, (p->>'min_seq')::int) else min_seq end,
    update_note = case when p ? 'update_note' then nullif(left(trim(p->>'update_note'), 300), '') else update_note end,
    updated_at  = now()
  where id = 1;
  return public.app_config_public();
end $function$;
