-- ════════════════════════════════════════════════════════════════════════════
--  ULETrack security — UNDO Stage 1 (only if you need to go fully back)
--  Run stage3-UNDO.sql first if Stage 3 was applied, and put the previous
--  version of the site back on GitHub, because this removes the new login.
--
--  Everyone's current password is restored to the old format, so all users
--  can keep signing in with the passwords they use today.
-- ════════════════════════════════════════════════════════════════════════════
begin;
-- Restore old-style hashes that were moved aside in Stage 3
update public.users u set password_hash = c.legacy_hash
  from public.app_credentials c
 where c.user_id = u.id and c.legacy_hash is not null;
-- Any account with no old-style hash at all gets a placeholder that matches no
-- password (an admin can reset it); needed because the old column is NOT NULL.
update public.users set password_hash = 'reset-required' where password_hash is null;
alter table public.users alter column password_hash set not null;

drop function if exists public.app_admin_set_password(uuid, text);
drop function if exists public.app_logout();
drop function if exists public.app_whoami();
drop function if exists public.app_register(text, text, text, text, text);
drop function if exists public.app_login(text, text);
drop function if exists public.app_new_session(uuid);
drop function if exists public.app_can_see_job(text);
drop function if exists public.app_is_admin();
drop function if exists public.app_is_manager();
drop function if exists public.app_is_staff();
drop function if exists public.app_role();
drop function if exists public.app_uid();
drop function if exists public.app_session_token();
drop function if exists public.app_legacy_hash(text);
drop table if exists public.app_sessions;
drop table if exists public.app_credentials;
commit;
select 'Stage 1 removed' as status,
       (select count(*) from public.users where password_hash is null) as users_needing_new_password;
