-- Security tidy-up (23 Oct 2026). Safe to run again.
--
-- Supabase gives anon (signed out) and authenticated (signed in) EXECUTE on every new function directly,
-- so an earlier "revoke ... from public" didn't stop them. This file sets who may call what:
--   1. Internal helpers: only the server (service_role, triggers, cron). Before this, anyone could read the
--      notification cron token, queue a push to any user, or claim and read the push queue.
--   2. Admin functions: signed-in only (each one also checks is_admin() inside).
--   3. Account functions that only make sense signed in: signed-in only.
--   4. Left open on purpose: get_share, share_seen (share pages), app_config_public, app_seen_ping,
--      beta_request, beta_status, and the helpers row-level security policies call
--      (is_admin, beta_ok, paid, can_read_song_file, on_song, ...).
--   5. Fixed search_path on the six functions the linter flagged.

do $$
declare f record;
begin
  -- 1. internal helpers: nobody but the server
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      '_notify', '_who', '_notify_cron_token', '_status_cron_token', '_admin_check',
      'notify_claim', 'notify_result', 'notify_scheduled',
      '_notify_beta_approved', '_notify_invite_accepted', '_notify_plan', '_notify_song_edited',
      'shared_songs_cleanup', 'profiles_reserved_guard', 'collab_invites_guard', 'shared_songs_guard')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;

  -- 2. admin functions: signed in only
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and (p.proname like 'admin\_%' or p.proname like 'beta\_admin\_%')
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;

  -- 3. account functions: signed in only
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'my_notify_prefs', 'set_notify_prefs', 'my_tickets', 'my_plan', 'my_storage',
      'push_register', 'push_forget', 'ai_take', 'redeem_beta_code')
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;

-- 5. fixed search_path
alter function public.collab_invites_guard() set search_path = public;
alter function public.shared_songs_guard() set search_path = public;
alter function public.username_key(text) set search_path = public;
alter function public.username_forms(text) set search_path = public;
alter function public.my_email() set search_path = public;
alter function public._has(text) set search_path = public;
