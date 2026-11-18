-- *[demo] admins previewing the Free plan keep their real plan underneath. Applied 9 Nov 2026. Safe to run again.
-- Before: Admin's "Preview Free plan" wrote tier='free' over the admin's own plans row, wiping an App Store Pro record
-- (source 'apple', its end date). Now previewing on your own account only sets plans.preview_free; plan_for treats
-- that as Free, and turning the preview off clears just the flag. Setting someone else's plan works as before.

alter table public.plans add column if not exists preview_free boolean not null default false;

create or replace function public.plan_for(p_user uuid)
 returns text
 language sql
 stable security definer
 set search_path to 'public', 'auth'
as $function$
  select case
    when p_user is null then 'free'
    when exists (select 1 from public.plans p where p.user_id = p_user and (p.tier = 'free' or p.preview_free)) then 'free'
    when exists (select 1 from public.app_admins a join auth.users u on lower(u.email) = lower(a.email) where u.id = p_user) then 'pro'
    when exists (select 1 from public.plans p where p.user_id = p_user and p.tier = 'pro' and (p.expires_at is null or p.expires_at > now())) then 'pro'
    when coalesce((select beta_unlocks from public.plan_config where id = 1), true)
     and (not coalesce((select gate from public.beta_config where id = 1), false)
          or exists (select 1 from public.beta_requests r join auth.users u on u.id = p_user
                     where r.status = 'approved' and (r.user_id = p_user or r.email = lower(u.email)))) then 'beta'
    else 'free'
  end
$function$;

create or replace function public.admin_set_plan(p_user uuid, p_tier text, p_days integer default null)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform public._admin_check();
  if p_tier = 'beta' then p_tier := 'auto'; end if;
  -- an admin previewing Free on their own account: only a flag, so an App Store (or any other) plan underneath is kept
  if p_user = auth.uid() and p_tier in ('free', 'auto') then
    insert into public.plans (user_id, tier, source, preview_free, updated_at)
    values (p_user, 'auto', 'admin', p_tier = 'free', now())
    on conflict (user_id) do update set preview_free = (p_tier = 'free'), updated_at = now();
    return public.plan_for(p_user);
  end if;
  if p_tier in ('free', 'pro', 'auto') then
    insert into public.plans (user_id, tier, source, expires_at, updated_at)
    values (p_user, p_tier, 'admin', case when p_tier = 'pro' and p_days is not null then now() + make_interval(days => p_days) end, now())
    on conflict (user_id) do update set tier = excluded.tier, source = 'admin', expires_at = excluded.expires_at, preview_free = false, updated_at = now();
  else
    raise exception 'Unknown plan %', p_tier;
  end if;
  return public.plan_for(p_user);
end $function$;
