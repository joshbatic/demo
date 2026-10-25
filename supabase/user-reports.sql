-- Reporting and blocking people (App Store guideline 1.2). Already applied; safe to run again.
-- Reports are sent through the support function ({ action: "report" }), which saves them here and emails ADMIN_EMAIL.
-- Admins see and close them; nobody else can read them. The reported person isn't told.

create table if not exists public.user_reports (
  id         bigint generated always as identity primary key,
  reporter   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  reported   uuid not null,
  song_id    text,
  reason     text not null check (reason in ('spam','harassment','inappropriate','impersonation','other')),
  details    text check (length(details) <= 2000),
  status     text not null default 'open' check (status in ('open','actioned','dismissed')),
  created_at timestamptz not null default now()
);
alter table public.user_reports enable row level security;
drop policy if exists "report as yourself" on public.user_reports;
drop policy if exists "admins read reports" on public.user_reports;
drop policy if exists "admins update reports" on public.user_reports;
create policy "report as yourself" on public.user_reports for insert to authenticated with check (reporter = auth.uid() and reported <> auth.uid());
create policy "admins read reports" on public.user_reports for select to authenticated using (public.is_admin());
create policy "admins update reports" on public.user_reports for update to authenticated using (public.is_admin());

-- Block someone: their invites stop, and pending invites either way are declined. The app also removes them from
-- your shared songs and leaves theirs (collab_members allows both from the client).
create or replace function public.block_user(p_user uuid) returns void language plpgsql security definer set search_path to 'public' as $$
declare me uuid := auth.uid();
begin
  if me is null or p_user is null or p_user = me then return; end if;
  insert into public.user_blocks (blocker, blocked) values (me, p_user) on conflict do nothing;
  update public.collab_invites set status = 'declined', responded_at = now()
    where status = 'pending' and ((owner_id = p_user and invitee_user_id = me) or (owner_id = me and invitee_user_id = p_user));
end $$;
revoke execute on function public.block_user(uuid) from public, anon;
grant execute on function public.block_user(uuid) to authenticated;

-- You can't invite someone you've blocked. (Their invites to you are already hidden by "not from blocked".)
drop policy if exists "collab_invites: not to blocked" on public.collab_invites;
create policy "collab_invites: not to blocked" on public.collab_invites as restrictive for insert to authenticated
  with check (invitee_user_id is null or not public.i_blocked(invitee_user_id));

-- Admin › Reports: the list (with who reported whom) and marking reports dealt with or dismissed.
alter table public.user_reports add column if not exists note text, add column if not exists handled_at timestamptz;

create or replace function public.admin_reports(p_status text default 'open')
returns jsonb language plpgsql stable security definer set search_path to 'public', 'auth' as $function$
declare r jsonb;
begin
  perform public._admin_check();
  select jsonb_build_object(
    'counts', (select jsonb_build_object('open', count(*) filter (where status = 'open'),
                 'actioned', count(*) filter (where status = 'actioned'), 'dismissed', count(*) filter (where status = 'dismissed'))
               from public.user_reports),
    'list', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
        select ur.id, ur.reason, ur.details, ur.song_id, ur.status, ur.note, ur.created_at, ur.handled_at,
               ur.reporter, ru.email as reporter_email, rp.username as reporter_username, rp.display_name as reporter_name,
               ur.reported, du.email as reported_email, dp.username as reported_username, dp.display_name as reported_name,
               (du.banned_until is not null and du.banned_until > now()) as reported_suspended,
               (select count(*) from public.user_reports z where z.reported = ur.reported) as reported_total,
               (select ss.data->>'title' from public.shared_songs ss where ss.id = ur.song_id) as song_title
        from public.user_reports ur
        left join auth.users ru on ru.id = ur.reporter left join public.profiles rp on rp.user_id = ur.reporter
        left join auth.users du on du.id = ur.reported left join public.profiles dp on dp.user_id = ur.reported
        where p_status = 'all' or ur.status = p_status
        order by ur.created_at desc limit 200) x), '[]'::jsonb))
  into r;
  return r;
end $function$;

create or replace function public.admin_report_update(p_id bigint, p_status text, p_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  perform public._admin_check();
  if p_status is not null and p_status not in ('open','actioned','dismissed') then raise exception 'Unknown status'; end if;
  update public.user_reports set
    status = coalesce(p_status, status),
    note = coalesce(p_note, note),
    handled_at = case when p_status is null then handled_at when p_status = 'open' then null else now() end
  where id = p_id;
end $function$;

revoke execute on function public.admin_reports(text) from public, anon;
revoke execute on function public.admin_report_update(bigint, text, text) from public, anon;
grant execute on function public.admin_reports(text) to authenticated;
grant execute on function public.admin_report_update(bigint, text, text) to authenticated;
