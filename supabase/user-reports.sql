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
