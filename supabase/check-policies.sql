-- *[demo] read-only check: lists the access rules on the tables the app uses, so they can be reviewed.
-- Run in Supabase: SQL Editor -> New query -> paste -> Run, then copy the result. It changes nothing.
select tablename, policyname, cmd, roles, qual as using_rule, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('profiles','cloud_library','shared_songs','collab_members','collab_invites','shares','muse_events','muse_profile')
order by tablename, cmd, policyname;

select c.relname as table_name, c.relrowsecurity as rls_on
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('profiles','cloud_library','shared_songs','collab_members','collab_invites','shares','muse_events','muse_profile');
