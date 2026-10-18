-- *[demo] AI limits per account. Run once in Supabase: SQL Editor -> New query -> paste -> Run. Safe to run again.
--
-- Every AI request (ai-proxy) and every minute of lyric sync (lyric-sync) is counted per account, and each
-- function asks ai_take() before calling OpenAI. Limits (change them here and run this file again):
--   ai    300 units a day (a quick request is 1 unit, a heavy one like Rate or the voice profile is 3), 30 a minute
--   sync  60 one-minute pieces of audio a day (about an hour of songs), 12 a minute
-- Days are UTC days. Counts older than 30 days are tidied away. Nobody can read or change the counts directly.

create table if not exists public.ai_calls (
  id       bigserial primary key,
  user_id  uuid not null references auth.users(id) on delete cascade,
  kind     text not null,
  units    int  not null default 1,
  at       timestamptz not null default now()
);
create index if not exists ai_calls_recent on public.ai_calls (user_id, kind, at desc);
alter table public.ai_calls enable row level security;

create or replace function public.ai_take(kind text, units int default 1)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
#variable_conflict use_variable
declare me uuid := auth.uid(); k text := coalesce(kind, 'ai'); u int := greatest(1, least(coalesce(units, 1), 10));
  day_limit int := case k when 'sync' then 60 else 300 end;
  minute_limit int := case k when 'sync' then 12 else 30 end;
  used int; recent int;
begin
  if me is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  -- with the beta waitlist lock on (beta-access.sql), only approved accounts can use AI
  if to_regprocedure('public.beta_ok()') is not null then
    if not public.beta_ok() then return jsonb_build_object('ok', false, 'reason', 'beta'); end if;
  end if;
  select coalesce(sum(c.units), 0) into used from public.ai_calls c where c.user_id = me and c.kind = k and c.at >= date_trunc('day', now());
  if used + u > day_limit then return jsonb_build_object('ok', false, 'reason', 'day', 'used', used, 'limit', day_limit); end if;
  select count(*) into recent from public.ai_calls c where c.user_id = me and c.kind = k and c.at > now() - interval '1 minute';
  if recent >= minute_limit then return jsonb_build_object('ok', false, 'reason', 'minute', 'limit', minute_limit); end if;
  insert into public.ai_calls (user_id, kind, units) values (me, k, u);
  if random() < 0.02 then delete from public.ai_calls c where c.user_id = me and c.at < now() - interval '30 days'; end if;
  return jsonb_build_object('ok', true, 'used', used + u, 'limit', day_limit);
end $$;
revoke all on function public.ai_take(text, int) from public, anon;
grant execute on function public.ai_take(text, int) to authenticated;
