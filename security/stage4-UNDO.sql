-- ULETrack — UNDO Stage 4 (removes rep info columns and release requests)
-- Deletes saved release requests, rep contact info, and the "requested by" info on releases. Nothing else is touched.
begin;
drop table if exists public.release_requests;
drop function if exists public.app_request_before_insert();
drop function if exists public.app_request_before_update();
alter table public.releases drop column if exists requested_by_name;
alter table public.releases drop column if exists requested_by_phone;
alter table public.releases drop column if exists requested_by_email;
alter table public.users drop column if exists rep_name;
alter table public.users drop column if exists rep_phone;
alter table public.users drop column if exists rep_email;
commit;
select 'Stage 4 removed' as status;
