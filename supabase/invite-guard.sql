-- Invites can only be answered once (23 Oct 2026). Safe to run again.
-- Before: the person invited could set an answered invite back to "pending" (or push responded_at forward),
-- which let someone the owner had removed from a song join it again.
create or replace function public.collab_invites_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is not null and auth.uid() is distinct from old.owner_id then
    if new.song_id is distinct from old.song_id or new.owner_id is distinct from old.owner_id
       or new.invitee_user_id is distinct from old.invitee_user_id or new.invitee_email is distinct from old.invitee_email then
      raise exception 'Only the person who sent an invite can change who or what it is for';
    end if;
    if old.status is distinct from 'pending' then
      if new.status is distinct from old.status or new.responded_at is distinct from old.responded_at then
        raise exception 'This invite has already been answered';
      end if;
    elsif new.status is distinct from old.status then
      if new.status not in ('accepted', 'declined') then
        raise exception 'An invite can only be accepted or declined';
      end if;
      new.responded_at := now();
    elsif new.responded_at is distinct from old.responded_at then
      new.responded_at := old.responded_at;
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.collab_invites_guard() from public, anon, authenticated;
