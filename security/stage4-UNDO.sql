-- ULETrack — UNDO Stage 4 (removes rep info columns and release requests)
-- Deletes any saved release requests and rep contact info. Nothing else is touched.
begin;
drop table if exists public.release_requests;
drop function if exists public.app_request_before_insert();
drop function if exists public.app_request_before_update();
alter table public.users drop column if exists rep_name;
alter table public.users drop column if exists rep_phone;
alter table public.users drop column if exists rep_email;
commit;
select 'Stage 4 removed' as status;
