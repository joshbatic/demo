-- Share links: a monthly cap on how often each link serves its audio, to keep bandwidth bounded.
-- Already applied. Over the cap the page still opens with the lyrics, without the audio, until the next month
-- (Adelaide time), and the owner gets one notification. Change it in Admin › Settings › Share Link Plays a Month.
-- (admin_overview and admin_set_setting were updated in the database to show and change it.)

create table if not exists public.share_audio_cap (
  id int primary key default 1 check (id = 1),
  per_link_month int default 1000 check (per_link_month is null or per_link_month >= 0)
);
insert into public.share_audio_cap (id, per_link_month) values (1, 1000) on conflict (id) do nothing;
alter table public.share_audio_cap enable row level security;
revoke all on public.share_audio_cap from anon, authenticated;

create table if not exists public.share_plays (
  share_id text not null references public.shares(id) on delete cascade,
  month date not null,
  opens int not null default 0,
  primary key (share_id, month)
);
alter table public.share_plays enable row level security;
revoke all on public.share_plays from anon, authenticated;

create or replace function public.get_share(sid text)
returns jsonb language plpgsql volatile security definer set search_path to 'public' as $function$
declare d jsonb; own uuid; ttl text; cap int; n int; m date := date_trunc('month', now() at time zone 'Australia/Adelaide')::date;
begin
  if sid is null or sid !~ '^[A-Za-z0-9]{10}$' then return null; end if;
  select data || jsonb_build_object('updated', extract(epoch from updated_at)::bigint), owner, data->>'title'
    into d, own, ttl from public.shares where id = sid;
  if d is null then return null; end if;
  if jsonb_typeof(d->'audio') = 'object' then
    insert into public.share_plays (share_id, month, opens) values (sid, m, 1)
      on conflict (share_id, month) do update set opens = public.share_plays.opens + 1
      returning opens into n;
    select per_link_month into cap from public.share_audio_cap where id = 1;
    if cap is not null and n > cap then
      d := (d - 'audio') || jsonb_build_object('audio_capped', true);
      if n = cap + 1 then
        begin
          perform public._notify(own, 'plays', 'Your song’s getting a lot of plays',
            '“' || coalesce(nullif(ttl, ''), 'Your song') || '” reached this month’s listening limit. The link still shows the lyrics; the audio comes back next month.',
            jsonb_build_object('share', sid), 'cap:' || sid || ':' || m::text);
        exception when others then null;
        end;
      end if;
    end if;
  end if;
  return d;
end $function$;
revoke all on function public.get_share(text) from public;
grant execute on function public.get_share(text) to anon, authenticated;
