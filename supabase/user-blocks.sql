-- Blocking: stop someone from inviting you to write.
-- Invites from someone you've blocked never reach you; they aren't told they're blocked.
-- You can see and undo your blocks in Account › Blocked.
-- Safe to run again. Blocks are removed automatically when either account is deleted.

create table if not exists public.user_blocks (
  blocker    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  blocked    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);

alter table public.user_blocks enable row level security;
revoke all on public.user_blocks from anon;
grant select, insert, delete on public.user_blocks to authenticated;

drop policy if exists "user_blocks: see own" on public.user_blocks;
drop policy if exists "user_blocks: add own" on public.user_blocks;
drop policy if exists "user_blocks: remove own" on public.user_blocks;
create policy "user_blocks: see own" on public.user_blocks for select to authenticated using (blocker = auth.uid());
create policy "user_blocks: add own" on public.user_blocks for insert to authenticated with check (blocker = auth.uid());
create policy "user_blocks: remove own" on public.user_blocks for delete to authenticated using (blocker = auth.uid());

create or replace function public.i_blocked(other uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.user_blocks where blocker = auth.uid() and blocked = other);
$$;
revoke execute on function public.i_blocked(uuid) from public, anon;
grant execute on function public.i_blocked(uuid) to authenticated;

-- Invites from people you've blocked are hidden from you (and so can't be accepted).
drop policy if exists "collab_invites: not from blocked" on public.collab_invites;
create policy "collab_invites: not from blocked" on public.collab_invites as restrictive for select to authenticated
  using (not public.i_blocked(owner_id));
