-- *[demo] private live channels. Run once in Supabase: SQL Editor -> New query -> paste -> Run. Safe to run again.
--
-- Live co-writing sends edits over Realtime channels named song:<song id>, and each account's devices talk over
-- library:<user id>. Without rules, anyone with the app's public key who knows a song id could join that song's
-- channel, read the lyrics as they're typed and push edits into it. With these rules:
--   song:<id>      only the song's owner and its co-writers can listen or send
--   library:<uid>  only that account can listen; anyone signed in can send it a nudge (used for invite
--                  notifications), which only makes the app re-check its own data
--
-- After running this: Supabase -> Project Settings -> Realtime -> turn OFF "Allow public access", so the old
-- open channels stop working too. The app already asks for private channels and falls back to open ones only
-- while this isn't set up.

create or replace function public.can_use_song_channel(song text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.shared_songs s where s.id::text = song and s.owner_id = auth.uid())
      or exists (select 1 from public.collab_members m where m.song_id::text = song and m.user_id = auth.uid())
$$;
revoke all on function public.can_use_song_channel(text) from public;
grant execute on function public.can_use_song_channel(text) to authenticated;

drop policy if exists "demo: song channel listen"    on realtime.messages;
drop policy if exists "demo: song channel send"      on realtime.messages;
drop policy if exists "demo: own library listen"     on realtime.messages;
drop policy if exists "demo: library nudge"          on realtime.messages;

create policy "demo: song channel listen" on realtime.messages for select to authenticated
  using (realtime.messages.extension = 'broadcast' and realtime.topic() like 'song:%'
         and public.can_use_song_channel(substr(realtime.topic(), 6)));
create policy "demo: song channel send" on realtime.messages for insert to authenticated
  with check (realtime.messages.extension = 'broadcast' and realtime.topic() like 'song:%'
              and public.can_use_song_channel(substr(realtime.topic(), 6)));

create policy "demo: own library listen" on realtime.messages for select to authenticated
  using (realtime.messages.extension = 'broadcast' and realtime.topic() = 'library:' || auth.uid()::text);
create policy "demo: library nudge" on realtime.messages for insert to authenticated
  with check (realtime.messages.extension = 'broadcast' and realtime.topic() like 'library:%');
