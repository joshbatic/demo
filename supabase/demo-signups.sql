-- *[demo] the exact email addresses allowed to sign up with email + password (App Review demo accounts).
-- Everyone else signs in with Apple (or Google). Run before signup-limit.sql. Add a row here to allow a new demo account.
create table if not exists public.demo_signups (email text primary key, note text, added_at timestamptz not null default now());
alter table public.demo_signups enable row level security;   -- no policies: only the sign-up hook reads it
insert into public.demo_signups (email, note) values
  ('review@hellodemo.app', 'App Review demo (Free)'),
  ('review2@hellodemo.app', 'App Review co-writer'),
  ('reviewpro@hellodemo.app', 'App Review demo (Pro)')
on conflict do nothing;
