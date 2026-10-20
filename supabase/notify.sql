-- *[demo] automatic notifications (iPhone push, through supabase/functions/push).
--
-- What's sent, and the switch for each in Account › Notifications:
--   cowrite  someone accepted your invite; a co-writer edited a shared song (once per 30 minutes per song)
--   nudge    a gentle prompt after 3+ days without writing: at most once a week, around 6pm where you are
--   account  beta approved; Pro given; Pro trial ends in 2 days; Pro ended
--   plays    your share link was opened (once a day per link)
-- Invites and help desk replies are always sent (supabase/functions/push and support).
--
-- How: database triggers and an hourly check put notifications in push_outbox; every minute, while anything is
-- waiting, pg_cron asks the push function to send them ({ action: "drain" }, with a token kept in Vault).
-- Needs push.sql first. Safe to run more than once.

-- ---------- what each person wants ----------
create table if not exists public.notify_prefs (
  user_id    uuid primary key,
  cowrite    boolean not null default true,
  nudge      boolean not null default true,
  account    boolean not null default true,
  plays      boolean not null default true,
  tz         text check (length(tz) <= 64),          -- the phone's time zone, for the 6pm nudge
  updated_at timestamptz not null default now()
);
alter table public.notify_prefs enable row level security;
revoke all on public.notify_prefs from anon, authenticated;

create or replace function public.my_notify_prefs() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('cowrite', cowrite, 'nudge', nudge, 'account', account, 'plays', plays)
    from public.notify_prefs where user_id = auth.uid()), '{"cowrite":true,"nudge":true,"account":true,"plays":true}'::jsonb)
$$;

create or replace function public.set_notify_prefs(p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;
  insert into public.notify_prefs (user_id) values (auth.uid()) on conflict (user_id) do nothing;
  update public.notify_prefs set
    cowrite = case when p ? 'cowrite' then (p->>'cowrite')::boolean else cowrite end,
    nudge   = case when p ? 'nudge'   then (p->>'nudge')::boolean   else nudge end,
    account = case when p ? 'account' then (p->>'account')::boolean else account end,
    plays   = case when p ? 'plays'   then (p->>'plays')::boolean   else plays end,
    tz      = case when p ? 'tz' and (p->>'tz') in (select name from pg_timezone_names) then p->>'tz' else tz end,
    updated_at = now()
  where user_id = auth.uid();
  return public.my_notify_prefs();
end $$;

-- ---------- the queue ----------
create table if not exists public.push_outbox (
  id         bigserial primary key,
  user_id    uuid not null,
  kind       text not null,
  title      text not null check (length(title) <= 120),
  body       text not null check (length(body) <= 240),
  data       jsonb not null default '{}'::jsonb,
  dedupe     text unique,                         -- the same notification is never queued twice
  created_at timestamptz not null default now(),
  sent_at    timestamptz,                         -- claimed for sending
  result     text check (length(result) <= 300)
);
create index if not exists push_outbox_waiting on public.push_outbox (created_at) where sent_at is null;
alter table public.push_outbox enable row level security;
revoke all on public.push_outbox from anon, authenticated;

-- a name to show in a notification
create or replace function public._who(p_user uuid) returns text
language sql stable security definer set search_path = public, auth as $$
  select coalesce(nullif(p.display_name, ''), '@' || nullif(p.username, ''),
                  (select coalesce(u.raw_user_meta_data->>'full_name', u.raw_user_meta_data->>'name') from auth.users u where u.id = p_user),
                  'Someone')
  from (select 1) x left join public.profiles p on p.user_id = p_user
$$;

-- queue one, if they want this kind and have a phone that can get it
create or replace function public._notify(p_user uuid, p_kind text, p_title text, p_body text, p_data jsonb, p_dedupe text) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if p_user is null then return; end if;
  if not coalesce((select case p_kind when 'cowrite' then cowrite when 'nudge' then nudge when 'account' then account
                   when 'plays' then plays else true end from public.notify_prefs where user_id = p_user), true) then return; end if;
  if not exists (select 1 from public.push_tokens where user_id = p_user) then return; end if;
  insert into public.push_outbox (user_id, kind, title, body, data, dedupe)
  values (p_user, p_kind, left(p_title, 120), left(p_body, 240), coalesce(p_data, '{}'::jsonb) || jsonb_build_object('kind', p_kind), p_dedupe)
  on conflict (dedupe) do nothing;
end $$;

-- ---------- co-writing ----------
create or replace function public._notify_invite_accepted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    perform public._notify(new.owner_id, 'cowrite', public._who(new.invitee_user_id) || ' accepted your invite',
      'You’re writing “' || coalesce(nullif(new.song_title, ''), 'your song') || '” together now.',
      jsonb_build_object('song', new.song_id), 'joined:' || new.id);
  end if;
  return new;
end $$;
create or replace trigger notify_invite_accepted after update of status on public.collab_invites
  for each row execute function public._notify_invite_accepted();

create or replace function public._notify_song_edited() returns trigger
language plpgsql security definer set search_path = public as $$
declare editor uuid := auth.uid(); t text; r uuid; bucket bigint := floor(extract(epoch from now()) / 1800);
begin
  if editor is null or new.data is not distinct from old.data then return new; end if;
  -- only real edits: the words, sections, chords or title, not who saved it or when
  if (new.data - 'lastEditBy' - 'lastEditAt' - 'updated') is not distinct from (old.data - 'lastEditBy' - 'lastEditAt' - 'updated') then return new; end if;
  t := coalesce(nullif(new.data->>'title', ''), 'a song');
  for r in select new.owner_id union select m.user_id from public.collab_members m where m.song_id = new.id loop
    if r is distinct from editor then
      perform public._notify(r, 'cowrite', public._who(editor) || ' edited “' || t || '”', 'Open it to see what changed.',
        jsonb_build_object('song', new.id), 'edit:' || new.id || ':' || r || ':' || bucket);
    end if;
  end loop;
  return new;
end $$;
create or replace trigger notify_song_edited after update on public.shared_songs
  for each row execute function public._notify_song_edited();

-- ---------- account & Pro ----------
create or replace function public._notify_beta_approved() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' and new.user_id is not null then
    perform public._notify(new.user_id, 'account', 'You’re in', 'Your *[demo] beta access is approved. Open the app and start writing.',
      jsonb_build_object('open', 'account'), 'beta:' || new.id);
  end if;
  return new;
end $$;
create or replace trigger notify_beta_approved after update of status on public.beta_requests
  for each row execute function public._notify_beta_approved();

alter table public.plans add column if not exists trial boolean not null default false;

create or replace function public._notify_plan() returns trigger
language plpgsql security definer set search_path = public as $$
declare was text := case when tg_op = 'UPDATE' then old.tier end;
begin
  -- given Pro (by you, from Admin), not bought: buyers already know
  if new.tier = 'pro' and was is distinct from 'pro' and coalesce(new.source, 'admin') = 'admin' then
    perform public._notify(new.user_id, 'account', 'You’ve got *[demo] Pro',
      case when new.expires_at is not null then 'Everything’s unlocked until ' || to_char(new.expires_at, 'FMDD Mon') || '.' else 'Everything’s unlocked. Enjoy.' end,
      jsonb_build_object('open', 'account'), 'pro:' || new.user_id || ':' || to_char(now(), 'YYYY-MM-DD'));
  end if;
  -- an App Store subscription ended (the RevenueCat sync moves it off Pro)
  if tg_op = 'UPDATE' and was = 'pro' and new.tier is distinct from 'pro' and old.source = 'apple' then
    perform public._notify(new.user_id, 'account', 'Your *[demo] Pro has ended',
      'Your songs are all still here. Pro is in Account if you want it back.', jsonb_build_object('open', 'account'),
      'ended:' || new.user_id || ':' || to_char(now(), 'YYYY-MM-DD'));
  end if;
  return new;
end $$;
create or replace trigger notify_plan after insert or update on public.plans
  for each row execute function public._notify_plan();

-- ---------- share link opened (called by the share page, listen.hellodemo.app) ----------
create or replace function public.share_seen(sid text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare s record;
begin
  if sid is null or sid !~ '^[A-Za-z0-9]{10}$' then return; end if;
  select id, owner, song_id, data->>'title' as title into s from public.shares where id = sid;
  if s.id is null then return; end if;
  perform public._notify(s.owner, 'plays', 'Someone’s listening',
    '“' || coalesce(nullif(s.title, ''), 'Your song') || '” was just opened from your share link.',
    jsonb_build_object('song', s.song_id), 'play:' || sid || ':' || to_char(now(), 'YYYY-MM-DD'));
end $$;

-- ---------- the hourly check: writing nudges, trials ending, given Pro ending ----------
create or replace function public.notify_scheduled() returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int := 0; r record;
  lines text[] := array[
    'One line is enough to start. What’s on your mind?',
    'Got a title in your head? Jot it down before it goes.',
    'Your songs miss you. Ten minutes tonight?',
    'Hum something into a voice memo. Future you will thank you.',
    'Pick up where you left off. The next line is waiting.'];
begin
  -- writing nudge: 3+ days since anything changed in their library, 6pm-ish where they are, at most once a week
  for r in
    select p.user_id, coalesce(p.tz, 'Australia/Adelaide') as tz, l.updated_at
    from public.notify_prefs p join public.cloud_library l on l.user_id = p.user_id
    where p.nudge and l.updated_at < now() - interval '3 days'
      and exists (select 1 from public.push_tokens t where t.user_id = p.user_id)
      and extract(hour from now() at time zone coalesce(p.tz, 'Australia/Adelaide')) = 18
      and not exists (select 1 from public.push_outbox o where o.user_id = p.user_id and o.kind = 'nudge' and o.created_at > now() - interval '7 days')
  loop
    perform public._notify(r.user_id, 'nudge', '*[demo]', lines[1 + (extract(doy from now())::int % array_length(lines, 1))],
      jsonb_build_object('open', 'songs'), 'nudge:' || r.user_id || ':' || to_char(now(), 'IYYY-IW'));
    n := n + 1;
  end loop;
  -- App Store free trial ends in about 2 days
  for r in select user_id, expires_at from public.plans
    where tier = 'pro' and source = 'apple' and trial and expires_at between now() + interval '47 hours' and now() + interval '49 hours'
  loop
    perform public._notify(r.user_id, 'account', 'Your free trial ends ' || to_char(r.expires_at, 'FMDay'),
      'Pro then renews through the App Store. Cancel any time in Settings › Apple ID › Subscriptions.',
      jsonb_build_object('open', 'account'), 'trial:' || r.user_id || ':' || to_char(r.expires_at, 'YYYY-MM-DD'));
    n := n + 1;
  end loop;
  -- Pro you gave with an end date has just ended
  for r in select user_id from public.plans
    where tier = 'pro' and coalesce(source, 'admin') = 'admin' and expires_at between now() - interval '1 hour' and now()
  loop
    perform public._notify(r.user_id, 'account', 'Your *[demo] Pro has ended',
      'Your songs are all still here. Pro is in Account if you want it back.', jsonb_build_object('open', 'account'),
      'ended:' || r.user_id || ':' || to_char(now(), 'YYYY-MM-DD'));
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- sending: the push function claims a batch ----------
create or replace function public.notify_claim(p_limit int default 100) returns setof public.push_outbox
language sql volatile security definer set search_path = public as $$
  update public.push_outbox o set sent_at = now()
  where o.id in (select id from public.push_outbox where sent_at is null and created_at > now() - interval '1 day'
                 order by id limit greatest(1, least(p_limit, 500)) for update skip locked)
  returning o.*
$$;
create or replace function public.notify_result(p_id bigint, p_result text) returns void
language sql volatile security definer set search_path = public as $$
  update public.push_outbox set result = left(p_result, 300) where id = p_id
$$;

do $$ begin
  if not exists (select 1 from vault.secrets where name = 'notify_cron_token') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'notify_cron_token', 'Lets the schedule send queued notifications');
  end if;
end $$;
create or replace function public._notify_cron_token() returns text
language sql stable security definer set search_path = public as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'notify_cron_token' limit 1
$$;

-- ---------- permissions ----------
revoke execute on function public.my_notify_prefs(), public.set_notify_prefs(jsonb), public._who(uuid),
  public._notify(uuid, text, text, text, jsonb, text), public.share_seen(text), public.notify_scheduled(),
  public.notify_claim(int), public.notify_result(bigint, text), public._notify_cron_token() from public;
grant execute on function public.my_notify_prefs(), public.set_notify_prefs(jsonb) to authenticated;
grant execute on function public.share_seen(text) to anon, authenticated;
grant execute on function public.notify_claim(int), public.notify_result(bigint, text), public._notify_cron_token() to service_role;

-- ---------- schedules ----------
do $$ begin
  perform cron.unschedule(jobid) from cron.job where jobname in ('notify-send', 'notify-hourly');
  -- every minute, only when something is waiting
  perform cron.schedule('notify-send', '* * * * *', $job$
    select net.http_post(
      url := 'https://cygfgurzvmbtcegkpnss.supabase.co/functions/v1/push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN5Z2ZndXJ6dm1idGNlZ2twbnNzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE2ODk0MTIsImV4cCI6MjEwNzI2NTQxMn0.kJhE1V8V_W1BIuu0iSVaLqa5GyxeOrUy0lrqylq4_Cs',
        'x-cron-token', (select decrypted_secret from vault.decrypted_secrets where name = 'notify_cron_token' limit 1)),
      body := '{"action":"drain"}'::jsonb,
      timeout_milliseconds := 30000)
    where exists (select 1 from public.push_outbox where sent_at is null)
  $job$);
  perform cron.schedule('notify-hourly', '2 * * * *', $job$ select public.notify_scheduled() $job$);
end $$;

notify pgrst, 'reload schema';
