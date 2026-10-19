-- Beta access: a waitlist with approval.
--   1. People ask for access on hellodemo.app/beta.html (through the `beta` Edge Function).
--   2. You approve or decline them in the app (Account › Beta Requests). Approving emails them the TestFlight
--      link and a personal invite code.
--   3. With the waitlist lock on, an account that isn't approved sees "You're on the waitlist" after signing in,
--      and the server refuses its AI requests and uploads.
-- An account is approved if its sign-in email matches an approved request, or it has entered that request's
-- invite code (for people who sign in with "Hide My Email", or a different email).
--
-- After running this file (safe to run again):
--   a) dev@hellodemo.app is the admin (added below). Sign in to the app with an account that uses that email
--      (not "Hide My Email"). To add another admin:
--        insert into public.app_admins (email) values (lower('someone@example.com')) on conflict do nothing;
--   b) Optional, before turning the lock on: approve everyone who already has an account:
--        insert into public.beta_requests (email, status, user_id, decided_at)
--        select lower(email), 'approved', id, now() from auth.users where email is not null
--        on conflict (email) do update set status = 'approved', user_id = excluded.user_id, decided_at = now();
--   c) Turn the lock on in the app (Account › Beta Requests › Waitlist Lock), or:
--        update public.beta_config set gate = true where id = 1;

create table if not exists public.beta_config (
  id   int primary key default 1 check (id = 1),
  gate boolean not null default false
);
insert into public.beta_config (id, gate) values (1, false) on conflict (id) do nothing;

create table if not exists public.app_admins (
  email text primary key check (email = lower(email))
);
insert into public.app_admins (email) values ('dev@hellodemo.app') on conflict do nothing;

create table if not exists public.beta_requests (
  id         uuid primary key default gen_random_uuid(),
  email      text not null unique check (email = lower(email) and length(email) between 3 and 254 and position('@' in email) > 1),
  name       text check (length(name) <= 100),
  role       text check (length(role) <= 60),
  heard      text check (length(heard) <= 200),
  link       text check (length(link) <= 300),
  note       text check (length(note) <= 1000),
  status     text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  code       text unique,
  user_id    uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  emailed_at timestamptz
);
create index if not exists beta_requests_user on public.beta_requests (user_id);
create index if not exists beta_requests_status on public.beta_requests (status, created_at);

-- Nobody reads or writes these tables directly; everything goes through the functions below.
alter table public.beta_config enable row level security;
alter table public.app_admins enable row level security;
alter table public.beta_requests enable row level security;
revoke all on public.beta_config, public.app_admins, public.beta_requests from anon, authenticated;

create or replace function public.my_email() returns text
language sql stable as $$ select lower(nullif(auth.jwt() ->> 'email', '')) $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_admins where email = public.my_email());
$$;

-- True when the signed-in account may use the app (lock off, admin, or approved).
create or replace function public.beta_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select not coalesce((select gate from public.beta_config where id = 1), false)
      or public.is_admin()
      or exists (select 1 from public.beta_requests r
                 where r.status = 'approved' and (r.user_id = auth.uid() or r.email = public.my_email()))
      -- an active Pro plan (bought or given) always gets in, whatever the waitlist says
      or exists (select 1 from public.plans p where p.user_id = auth.uid() and p.tier = 'pro'
                 and (p.expires_at is null or p.expires_at > now()));
$$;

-- For the app after sign-in: 'open' (lock off), 'admin', 'approved', 'pending', 'declined' or 'none'.
create or replace function public.beta_status() returns text
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); em text := public.my_email(); r public.beta_requests;
begin
  if me is null then return 'none'; end if;
  if public.is_admin() then return 'admin'; end if;
  select * into r from public.beta_requests b
   where b.user_id = me or b.email = em
   order by (b.status = 'approved') desc, (b.user_id = me) desc limit 1;
  if found and r.status = 'approved' then
    if r.user_id is null then update public.beta_requests set user_id = me where id = r.id; end if;
    return 'approved';
  end if;
  if exists (select 1 from public.plans p where p.user_id = me and p.tier = 'pro' and (p.expires_at is null or p.expires_at > now())) then
    return 'approved';
  end if;
  if not coalesce((select gate from public.beta_config where id = 1), false) then return 'open'; end if;
  if found then return r.status; end if;
  return 'none';
end $$;

-- An invite code ties the signed-in account to an approved request.
create or replace function public.redeem_beta_code(code text) returns text
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); c text := upper(regexp_replace(coalesce(code, ''), '[^A-Za-z0-9]', '', 'g')); rid uuid;
begin
  if me is null or length(c) < 6 then return 'invalid'; end if;
  select id into rid from public.beta_requests b
   where b.code = c and b.status = 'approved' and (b.user_id is null or b.user_id = me);
  if rid is null then perform pg_sleep(0.5); return 'invalid'; end if;
  update public.beta_requests set user_id = me where id = rid;
  return 'approved';
end $$;

-- From the website form (through the beta Edge Function): add a request. Returns 'new' or 'exists'
-- (the form shows the same message either way, so it can't be used to check who has applied).
create or replace function public.beta_request(p_email text, p_name text, p_role text, p_heard text, p_link text, p_note text)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare em text := lower(trim(coalesce(p_email, '')));
begin
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(em) > 254 then raise exception 'Enter a valid email address.'; end if;
  if (select count(*) from public.beta_requests where created_at > now() - interval '1 day') >= 300 then
    raise exception 'We''ve had a lot of requests today. Please try again tomorrow.';
  end if;
  insert into public.beta_requests (email, name, role, heard, link, note)
  values (em, left(trim(p_name), 100), left(trim(p_role), 60), left(trim(p_heard), 200), left(trim(p_link), 300), left(trim(p_note), 1000))
  on conflict (email) do nothing;
  return case when found then 'new' else 'exists' end;
end $$;

-- ---------- for admins (Account › Beta Requests) ----------
create or replace function public.beta_admin_list(p_status text default 'pending')
returns setof public.beta_requests
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query select * from public.beta_requests where status = coalesce(p_status, 'pending') order by created_at desc limit 500;
end $$;

create or replace function public.beta_admin_summary() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return jsonb_build_object(
    'pending',  (select count(*) from public.beta_requests where status = 'pending'),
    'approved', (select count(*) from public.beta_requests where status = 'approved'),
    'declined', (select count(*) from public.beta_requests where status = 'declined'),
    'gate',     coalesce((select gate from public.beta_config where id = 1), false));
end $$;

create or replace function public.beta_admin_decide(p_id uuid, p_approve boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r public.beta_requests; c text; alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; h text; i int;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  select * into r from public.beta_requests where id = p_id for update;
  if not found then raise exception 'That request no longer exists.'; end if;
  if p_approve then
    c := r.code;
    while c is null loop
      h := replace(gen_random_uuid()::text, '-', '');
      c := '';
      for i in 0..7 loop c := c || substr(alpha, (('x' || substr(h, i * 2 + 1, 2))::bit(8)::int % 32) + 1, 1); end loop;
      if exists (select 1 from public.beta_requests where code = c) then c := null; end if;
    end loop;
    update public.beta_requests set status = 'approved', code = c, decided_at = now() where id = p_id returning * into r;
  else
    update public.beta_requests set status = 'declined', decided_at = now() where id = p_id returning * into r;
  end if;
  return jsonb_build_object('id', r.id, 'email', r.email, 'name', r.name, 'status', r.status, 'code', r.code, 'emailed_at', r.emailed_at);
end $$;

create or replace function public.beta_admin_mark_emailed(p_id uuid) returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.beta_requests set emailed_at = now() where id = p_id;
end $$;

create or replace function public.beta_admin_set_gate(p_on boolean) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.beta_config set gate = coalesce(p_on, false) where id = 1;
  return coalesce(p_on, false);
end $$;

revoke execute on function public.my_email(), public.is_admin(), public.beta_ok(), public.beta_status(), public.redeem_beta_code(text),
  public.beta_request(text, text, text, text, text, text), public.beta_admin_list(text), public.beta_admin_summary(),
  public.beta_admin_decide(uuid, boolean), public.beta_admin_mark_emailed(uuid), public.beta_admin_set_gate(boolean) from public;
grant execute on function public.my_email(), public.is_admin(), public.beta_ok(), public.beta_status(), public.redeem_beta_code(text),
  public.beta_admin_list(text), public.beta_admin_summary(), public.beta_admin_decide(uuid, boolean),
  public.beta_admin_mark_emailed(uuid), public.beta_admin_set_gate(boolean) to authenticated;
grant execute on function public.beta_request(text, text, text, text, text, text) to anon, authenticated;

-- With the lock on, accounts that aren't approved can't upload (AI requests are checked in ai_take, ai-limits.sql).
drop policy if exists "storage: beta approved" on storage.objects;
create policy "storage: beta approved" on storage.objects as restrictive for insert to authenticated
  with check (bucket_id not in ('song-files', 'shares') or public.beta_ok());
