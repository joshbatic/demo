-- Dashboard: what AI and lyric sync are costing, estimated from ai_calls (admins only).
-- Estimates per request (US$): quick AI (gpt-5-mini, 1 unit) 0.001 · Rate / voice (gpt-5, 3 units) 0.035 ·
-- lyric sync (Whisper, one unit per minute of audio) 0.006. Split by each account's plan today.
create or replace function public.admin_ai_cost()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  perform public._admin_check();
  with c as (
    select a.at, case when public.plan_for(a.user_id) = 'free' then 'free' else 'paid' end as tier,
           case when a.kind = 'sync' then a.units * 0.006 when a.units >= 3 then 0.035 else a.units * 0.001 end as usd
    from public.ai_calls a where a.at >= date_trunc('month', now()) - interval '1 month'
  )
  select jsonb_build_object(
    'today_usd', coalesce(sum(usd) filter (where at >= date_trunc('day', now())), 0),
    'today_free_usd', coalesce(sum(usd) filter (where at >= date_trunc('day', now()) and tier = 'free'), 0),
    'month_usd', coalesce(sum(usd) filter (where at >= date_trunc('month', now())), 0),
    'month_free_usd', coalesce(sum(usd) filter (where at >= date_trunc('month', now()) and tier = 'free'), 0),
    'last_month_usd', coalesce(sum(usd) filter (where at < date_trunc('month', now())), 0),
    'paid_users_month', (select count(distinct user_id) from public.ai_calls where at >= date_trunc('month', now()) and public.plan_for(user_id) <> 'free'),
    'free_users_month', (select count(distinct user_id) from public.ai_calls where at >= date_trunc('month', now()) and public.plan_for(user_id) = 'free'),
    'days', (select coalesce(jsonb_agg(d order by d->>'day'), '[]'::jsonb) from (
       select jsonb_build_object('day', g::date, 'usd', coalesce((select sum(usd) from c where c.at >= g and c.at < g + interval '1 day'), 0)) d
       from generate_series(date_trunc('day', now()) - interval '13 days', date_trunc('day', now()), interval '1 day') g) x)
  ) into r from c;
  return r;
end $$;
revoke all on function public.admin_ai_cost() from public, anon;
grant execute on function public.admin_ai_cost() to authenticated;
