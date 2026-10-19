-- *[demo] push notifications (iPhone): where to send them.
-- Each iPhone that allows notifications registers Apple's device token here; supabase/functions/push sends to them.
-- A token belongs to whoever last signed in on that phone. Signing out (or Apple saying the token is dead) clears its
-- owner, so nothing is ever sent to a phone someone has signed out of.
-- Safe to run more than once.

create table if not exists public.push_tokens (
  token      text primary key check (length(token) between 32 and 200),
  user_id    uuid,                                     -- null = signed out on that phone, or the token stopped working
  topic      text not null check (topic in ('app.hellodemo.demo', 'app.hellodemo.demo.dev')),   -- which app it's for
  env        text check (env in ('production', 'sandbox')),   -- learned on the first send (Xcode builds use sandbox)
  build      text check (length(build) <= 40),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_sent  timestamptz,
  last_error text check (length(last_error) <= 200)
);
create index if not exists push_tokens_user on public.push_tokens (user_id);
alter table public.push_tokens enable row level security;
revoke all on public.push_tokens from anon, authenticated;

-- the app, after the person allows notifications (and on each launch, since tokens can change)
create or replace function public.push_register(p_token text, p_topic text, p_build text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null or p_token is null or p_token !~ '^[0-9a-fA-F]{32,200}$' then return; end if;
  if p_topic not in ('app.hellodemo.demo', 'app.hellodemo.demo.dev') then return; end if;
  insert into public.push_tokens (token, user_id, topic, build) values (lower(p_token), auth.uid(), p_topic, left(p_build, 40))
  on conflict (token) do update set user_id = auth.uid(), topic = excluded.topic, build = excluded.build,
    updated_at = now(), last_error = null;
end $$;

-- the app, when someone signs out on that phone
create or replace function public.push_forget(p_token text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  update public.push_tokens set user_id = null, updated_at = now() where token = lower(p_token) and user_id = auth.uid();
end $$;

-- how many phones can get notifications, for Admin › Users › someone
create or replace function public.admin_push_devices(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._admin_check();
  return coalesce((select jsonb_agg(jsonb_build_object('topic', topic, 'env', env, 'build', build, 'updated_at', updated_at,
    'last_sent', last_sent, 'last_error', last_error) order by updated_at desc) from public.push_tokens where user_id = p_user), '[]'::jsonb);
end $$;

revoke execute on function public.push_register(text, text, text), public.push_forget(text), public.admin_push_devices(uuid) from public;
grant execute on function public.push_register(text, text, text), public.push_forget(text), public.admin_push_devices(uuid) to authenticated;

notify pgrst, 'reload schema';
