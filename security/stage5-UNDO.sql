-- ULETrack — UNDO Stage 5 (turns email notifications off and removes them)
select cron.unschedule(jobid) from cron.job where jobname in ('uletrack-notify-outbox','uletrack-notify-weekly');
begin;
drop trigger if exists trg_outbox_release on public.releases;
drop trigger if exists trg_outbox_request on public.release_requests;
drop function if exists public.app_outbox_release();
drop function if exists public.app_outbox_request();
drop function if exists public.app_notify_test(text);
drop function if exists public.app_set_my_notify(text, boolean);
drop function if exists public.app_notify_call(jsonb);
drop table if exists public.notify_outbox;
drop table if exists public.notify_config;
alter table public.users drop constraint if exists users_notify_pref_chk;
alter table public.users drop column if exists notify_requests;
alter table public.users drop column if exists notify_pref;
commit;
select 'Stage 5 removed' as status;
