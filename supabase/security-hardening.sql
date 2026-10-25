-- Security tightening (25 Oct 2026). Already applied; safe to run again.

-- 1. The checks the database's rules use (who owns or writes on a song, who's an admin, whether a feature is
--    off) only run for signed-in people. Before, they could be called without signing in, which let someone
--    who knew a song's internal id ask whether a given account was on it.
do $$
declare f text;
begin
  foreach f in array array[
    'public.is_song_member(text, uuid)', 'public.is_song_owner(text, uuid)', 'public.on_song(text, uuid)',
    'public.owns_song(text)', 'public.has_invite(text)', 'public.can_read_song_file(text, text)',
    'public.can_use_song_channel(text)', 'public.is_admin()', 'public.feature_off(text)',
    'public.beta_ok()', 'public.beta_status()'
  ] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

-- 2. profiles.pro and pro_since are old and unused (Pro comes from plans / my_plan()), but people could set
--    them on their own profile. Now only the server can. People can still change everything they edit.
revoke insert, update on public.profiles from anon, authenticated;
grant insert (user_id, updated_at, username, display_name, avatar_url, link_spotify, link_instagram, link_tiktok,
              link_youtube, link_x, link_website, link_apple_music) on public.profiles to authenticated;
grant update (user_id, updated_at, username, display_name, avatar_url, link_spotify, link_instagram, link_tiktok,
              link_youtube, link_x, link_website, link_apple_music) on public.profiles to authenticated;
