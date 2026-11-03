-- The business master sheet, kept in the [developer] app (Dashboard › Business): one row per sheet
-- (Overview, Services, Supabase, Setup, Features, Security, Builds, Repo). Admins only.
--   cols: [{n: name, k: 'status' | 'money' | null, o: [status options]}]
--   rows: [{s: 'Section name'} | {c: ['cell', 'cell', …]}]
create table if not exists public.biz_sheets (
  id text primary key,
  name text not null,
  sort int not null default 0,
  title text not null default '',
  note text not null default '',
  cols jsonb not null default '[]'::jsonb,
  rows jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
alter table public.biz_sheets enable row level security;
drop policy if exists "admins read biz" on public.biz_sheets;
drop policy if exists "admins write biz" on public.biz_sheets;
create policy "admins read biz" on public.biz_sheets for select to authenticated using (public.is_admin());
create policy "admins write biz" on public.biz_sheets for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.biz_sheets from anon;
grant select, insert, update, delete on public.biz_sheets to authenticated;

-- Tasks and jobs for Dashboard › Business (the board and the task list). Admins only.
create table if not exists public.biz_tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null default '',
  notes text not null default '',
  status text not null default 'todo' check (status in ('todo','doing','done')),
  area text not null default '',
  due date,
  sort double precision not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  done_at timestamptz
);
alter table public.biz_tasks enable row level security;
create policy "admins read tasks" on public.biz_tasks for select to authenticated using (public.is_admin());
create policy "admins write tasks" on public.biz_tasks for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.biz_tasks from anon;
grant select, insert, update, delete on public.biz_tasks to authenticated;
