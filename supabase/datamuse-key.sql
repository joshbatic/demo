-- *[demo] Datamuse key. Applied 4 Nov 2026 (migration datamuse_key_in_config). Safe to run again.
--
-- Datamuse asks for a key ("k") on every request from 1 January 2027. It identifies our traffic rather than
-- billing it, but it still doesn't belong in this public repo: it lives in app_config and comes to signed-in
-- people with the remote settings (app_config_public), which the apps already read.
--
-- Set or change it (SQL editor):  update public.app_config set dm_key = '<the key>' where id = 1;

alter table public.app_config add column if not exists dm_key text;

create or replace function public.app_config_public()
 returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object('banner', nullif(banner, ''), 'banner_kind', banner_kind, 'banner_id', banner_id,
    'ai_off', ai_off, 'sync_off', sync_off, 'uploads_off', uploads_off, 'min_seq', min_seq, 'update_note', update_note,
    'updated_at', updated_at,
    'dm_key', case when auth.uid() is not null then nullif(dm_key, '') end)
  from public.app_config where id = 1
$function$;
