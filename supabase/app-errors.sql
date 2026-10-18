-- *[demo] error reports from testers' devices. Run once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to run again.
--
-- The app reports script errors and every "Couldn't ..." message a person sees, with the build number,
-- platform and screen, so problems on testers' phones are visible. Signed-in accounts can only add their
-- own reports; nobody can read them through the app. Read them in the dashboard:
--   Table Editor > app_errors, or SQL:  select at, build, platform, kind, message from app_errors order by at desc limit 100;

create table if not exists public.app_errors (
  id        bigserial primary key,
  user_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  at        timestamptz not null default now(),
  build     text check (length(build) <= 40),
  platform  text check (length(platform) <= 40),
  kind      text check (length(kind) <= 40),
  screen    text check (length(screen) <= 40),
  message   text not null check (length(message) <= 600),
  detail    text check (length(detail) <= 2000)
);
create index if not exists app_errors_recent on public.app_errors (at desc);
alter table public.app_errors enable row level security;
drop policy if exists "app_errors: add own" on public.app_errors;
create policy "app_errors: add own" on public.app_errors for insert to authenticated with check (user_id = auth.uid());
