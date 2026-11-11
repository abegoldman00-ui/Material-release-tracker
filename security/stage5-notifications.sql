-- ════════════════════════════════════════════════════════════════════════════
--  ULETrack — STAGE 5: email notifications
--  Run after Stages 1–4, AFTER the "notify" Edge Function is deployed.
--  Additive only. Safe to run again.
--
--  • Release updates  → customer contacts on the job (new release, or Delivered)
--  • New requests     → the requester's ULE rep + staff who opted in
--  • Friday summary   → customer contacts, one email per person (Fridays ~2pm ET)
--
--  How it works: saving a release/request drops a row in notify_outbox; every
--  minute (only when something is waiting) the database calls the notify
--  function, which groups rows (a bulk release = one email) and sends via Resend.
--
--  Pause everything:  update public.notify_config set value='true' where key='paused';
--  Undo:              stage5-UNDO.sql
-- ════════════════════════════════════════════════════════════════════════════
create extension if not exists pg_net;
create extension if not exists pg_cron;

begin;

-- 1) Who wants what
alter table public.users add column if not exists notify_pref text not null default 'all';      -- all | weekly | off
alter table public.users add column if not exists notify_requests boolean not null default false; -- staff: email me new requests
do $$ begin
  alter table public.users add constraint users_notify_pref_chk check (notify_pref in ('all','weekly','off'));
exception when duplicate_object then null; end $$;

-- 2) Settings + outbox (hidden from browsers: RLS on, no rules)
create table if not exists public.notify_config (key text primary key, value text);
alter table public.notify_config enable row level security;
revoke all on public.notify_config from anon, authenticated;
insert into public.notify_config(key, value) values
  ('function_url', 'https://vusofoyhybywwwnvrjea.supabase.co/functions/v1/notify'),
  ('secret', encode(extensions.gen_random_bytes(24), 'hex')),
  ('paused', 'false')
on conflict (key) do nothing;

create table if not exists public.notify_outbox (
  id         bigserial primary key,
  kind       text not null,          -- release | release_status | request
  job_id     text,
  ref        text not null,          -- groups rows into one email (bulk id / request group)
  row_id     text,
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  result     text
);
alter table public.notify_outbox add column if not exists attempts int not null default 0;
create index if not exists notify_outbox_pending on public.notify_outbox(created_at) where sent_at is null;
alter table public.notify_outbox enable row level security;
revoke all on public.notify_outbox from anon, authenticated;

-- 3) Triggers that fill the outbox
create or replace function public.app_outbox_release()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.notify_outbox(kind, job_id, ref, row_id)
    values ('release', new.job_id, coalesce(new.bulk_id, new.id::text), new.id::text);
  elsif new.status is distinct from old.status and new.status = 'Delivered' then
    insert into public.notify_outbox(kind, job_id, ref, row_id)
    values ('release_status', new.job_id, coalesce(new.bulk_id, new.id::text) || ':delivered', new.id::text);
  end if;
  return new;
end $$;
drop trigger if exists trg_outbox_release on public.releases;
create trigger trg_outbox_release after insert or update of status on public.releases
  for each row execute function public.app_outbox_release();

create or replace function public.app_outbox_request()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.notify_outbox(kind, job_id, ref, row_id)
  values ('request', new.job_id, new.request_group, new.id::text);
  return new;
end $$;
drop trigger if exists trg_outbox_request on public.release_requests;
create trigger trg_outbox_request after insert on public.release_requests
  for each row execute function public.app_outbox_request();

-- 4) Calling the function
create or replace function public.app_notify_call(p_body jsonb)
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare u text; s text; rid bigint;
begin
  select value into u from public.notify_config where key = 'function_url';
  select value into s from public.notify_config where key = 'secret';
  select net.http_post(url := u,
                       headers := jsonb_build_object('Content-Type','application/json','x-notify-secret', s),
                       body := p_body,
                       timeout_milliseconds := 30000) into rid;
  return rid;
end $$;
revoke execute on function public.app_notify_call(jsonb) from public, anon, authenticated;

-- 5) Browser-callable helpers
-- Signed-in user sets their own email preferences
create or replace function public.app_set_my_notify(p_pref text, p_requests boolean default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.app_uid() is null then raise exception 'Not signed in'; end if;
  if p_pref not in ('all','weekly','off') then raise exception 'Invalid preference'; end if;
  update public.users
     set notify_pref = p_pref,
         notify_requests = case when public.app_is_staff() and p_requests is not null then p_requests else notify_requests end
   where id = public.app_uid();
end $$;
grant execute on function public.app_set_my_notify(text, boolean) to anon, authenticated;

-- Admin: send a test email to an address
create or replace function public.app_notify_test(p_to text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not public.app_is_admin() then raise exception 'Admins only'; end if;
  perform public.app_notify_call(jsonb_build_object('mode','test','to',p_to));
  return 'queued';
end $$;
grant execute on function public.app_notify_test(text) to anon, authenticated;

commit;

-- 6) Schedules (UTC). Outbox every minute — only calls out when something is waiting.
select cron.unschedule(jobid) from cron.job where jobname in ('uletrack-notify-outbox','uletrack-notify-weekly');
select cron.schedule('uletrack-notify-outbox', '* * * * *', $cron$
  select public.app_notify_call('{"mode":"outbox"}'::jsonb)
   where exists (select 1 from public.notify_outbox where sent_at is null and created_at < now() - interval '45 seconds')
     and coalesce((select value from public.notify_config where key='paused'),'false') <> 'true'
$cron$);
-- Fridays 19:00 UTC = 2pm EST (3pm during daylight time)
select cron.schedule('uletrack-notify-weekly', '0 19 * * 5', $cron$
  select public.app_notify_call('{"mode":"weekly"}'::jsonb)
   where coalesce((select value from public.notify_config where key='paused'),'false') <> 'true'
$cron$);

select 'Stage 5 installed' as status,
       (select count(*) from cron.job where jobname like 'uletrack-notify-%') as schedules,
       (select count(*) from information_schema.columns where table_schema='public' and table_name='users' and column_name in ('notify_pref','notify_requests')) as pref_columns;
