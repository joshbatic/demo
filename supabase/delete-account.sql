-- *[demo] account deletion (App Store requirement). Run once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to run again.
--
-- delete_my_account() deletes everything belonging to the signed-in account, then the account itself:
--   songs and library, ideas (they live in the library), profile, share links, co-writing (songs they own stop
--   being shared, so they leave co-writers' libraries too; songs they co-write simply lose them), muse memory,
--   AI usage counts, error reports, artist page and fan sign-ups if those exist.
-- Files (recordings, artwork, share-link audio) are removed by the app first, through Storage, because
-- Supabase doesn't let SQL delete stored files.
-- Each table is only touched if it exists, so this works whichever other setup files have been run.

create or replace function public.delete_my_account()
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if to_regclass('public.shared_songs') is not null then
    -- co-writers and invites on songs they own go with the songs
    if to_regclass('public.collab_members') is not null then delete from public.collab_members m where m.song_id::text in (select s.id::text from public.shared_songs s where s.owner_id = me); end if;
    if to_regclass('public.collab_invites') is not null then delete from public.collab_invites i where i.song_id::text in (select s.id::text from public.shared_songs s where s.owner_id = me); end if;
    delete from public.shared_songs where owner_id = me;
  end if;
  if to_regclass('public.collab_members') is not null then delete from public.collab_members where user_id = me; end if;
  if to_regclass('public.collab_invites') is not null then delete from public.collab_invites where owner_id = me or invitee_user_id = me; end if;
  if to_regclass('public.shares')         is not null then delete from public.shares         where owner = me; end if;
  if to_regclass('public.muse_events')    is not null then delete from public.muse_events    where user_id = me; end if;
  if to_regclass('public.muse_profile')   is not null then delete from public.muse_profile   where user_id = me; end if;
  if to_regclass('public.ai_calls')       is not null then delete from public.ai_calls       where user_id = me; end if;
  if to_regclass('public.app_errors')     is not null then delete from public.app_errors     where user_id = me; end if;
  if to_regclass('public.artist_fans')    is not null then delete from public.artist_fans    where artist_id = me; end if;
  if to_regclass('public.artist_pages')   is not null then delete from public.artist_pages   where user_id = me; end if;
  if to_regclass('public.beta_requests')  is not null then delete from public.beta_requests  where user_id = me or email = lower(auth.jwt() ->> 'email'); end if;
  if to_regclass('public.cloud_library')  is not null then delete from public.cloud_library  where user_id = me; end if;
  if to_regclass('public.profiles')       is not null then delete from public.profiles       where user_id = me; end if;
  -- added 23 Oct 2026: plan, phones, notification settings and queue, help desk tickets, device check-ins, blocks
  if to_regclass('public.plans')          is not null then delete from public.plans          where user_id = me; end if;
  if to_regclass('public.push_tokens')    is not null then delete from public.push_tokens    where user_id = me; end if;
  if to_regclass('public.push_outbox')    is not null then delete from public.push_outbox    where user_id = me; end if;
  if to_regclass('public.notify_prefs')   is not null then delete from public.notify_prefs   where user_id = me; end if;
  if to_regclass('public.support_tickets') is not null then delete from public.support_tickets where user_id = me; end if;
  if to_regclass('public.app_seen')       is not null then delete from public.app_seen       where user_id = me; end if;
  if to_regclass('public.user_blocks')    is not null then delete from public.user_blocks    where blocker = me or blocked = me; end if;
  delete from auth.users where id = me;
  return 'deleted';
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
