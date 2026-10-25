-- Usernames and display names: no slurs, sexual words or hate terms. Already applied; safe to run again.
-- Checked by the profiles_reserved_guard trigger (with the reserved names) on every insert and change, so it holds
-- whichever app, or the API directly, is used. Look-alikes count: "sh1t", "f_u_c_k" and "fuuuck" are all caught.
--   mode 'contains': refused anywhere in a username or display name
--   mode 'exact':    only refused as the whole username, because it turns up inside ordinary words
--                    ("dick" in "dickens", "rape" in "grapes", "anal" in "analysis")
-- Add a word: insert into public.banned_name_words (word, mode) values ('word', 'contains');

create table if not exists public.banned_name_words (
  word text primary key check (word ~ '^[a-z]+$'),
  mode text not null default 'contains' check (mode in ('contains','exact'))
);
alter table public.banned_name_words enable row level security;
revoke all on public.banned_name_words from anon, authenticated;
-- (the word list itself was inserted when this was applied; see Supabase › Table Editor › banned_name_words)

create or replace function public.name_letters(t text) returns text language sql immutable set search_path to 'public' as $$
  select regexp_replace(translate(lower(coalesce(t, '')), '013457@$!|', 'oieastasii'), '[^a-z]', '', 'g')
$$;
create or replace function public.name_squash(t text) returns text language sql immutable set search_path to 'public' as $$
  select regexp_replace(public.name_letters(t), '(.)\1+', '\1', 'g')
$$;
create or replace function public.name_is_banned(t text, strong_only boolean default false) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from public.banned_name_words w
    where (w.mode = 'contains' and (public.name_letters(t) like '%' || w.word || '%'
             or (length(public.name_squash(w.word)) >= 4 and public.name_squash(t) like '%' || public.name_squash(w.word) || '%')))
       or (not strong_only and w.mode = 'exact' and public.name_letters(t) = w.word)
  )
$$;
revoke execute on function public.name_is_banned(text, boolean) from public, anon;
grant execute on function public.name_is_banned(text, boolean) to authenticated;

create or replace function public.profiles_reserved_guard() returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if new.username is not null and (tg_op = 'INSERT' or new.username is distinct from old.username)
     and public.name_is_banned(new.username) then
    raise exception 'banned_username: That username isn''t allowed.' using errcode = 'P0001';
  end if;
  if new.display_name is not null and (tg_op = 'INSERT' or new.display_name is distinct from old.display_name)
     and public.name_is_banned(new.display_name, true) then
    raise exception 'banned_name: That name isn''t allowed.' using errcode = 'P0001';
  end if;
  if new.username is not null and (tg_op = 'INSERT' or new.username is distinct from old.username)
     and exists (select 1 from public.reserved_usernames r
                 where (r.key = public.username_key(new.username)
                        or (r.kind = 'artist' and r.key = any(public.username_forms(new.username))))
                   and r.key <> '' and (r.granted_to is null or r.granted_to is distinct from new.user_id)) then
    raise exception 'reserved_username: That username is reserved.' using errcode = 'P0001';
  end if;
  return new;
end $function$;
