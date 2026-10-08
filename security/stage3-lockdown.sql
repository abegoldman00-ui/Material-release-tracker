-- ════════════════════════════════════════════════════════════════════════════
--  ULETrack security — STAGE 3: lock down the database
--  Run ONLY after Stage 1 is installed and the updated site (Stage 2) is live
--  and its security check passes. Run at a quiet time.
--
--  What this does:
--   • Removes the "Allow all" rules from every table.
--   • Adds per-role rules the database enforces no matter what a browser does:
--       – Admins / PMs / coordinators (ULE staff): see all jobs; PMs + admins
--         can create/edit jobs; all staff can log/edit releases.
--       – Customers: read-only, and ONLY the jobs assigned to them.
--       – Only admins can manage users and invites.
--       – Nobody without a valid sign-in can see anything.
--   • Moves the remaining old-style password hashes into the hidden
--     app_credentials table and blanks them out of the users table.
--   • Closes the old password-reset table to browsers entirely.
--
--  Undo: run stage3-UNDO.sql (restores "Allow all"; data is untouched).
-- ════════════════════════════════════════════════════════════════════════════

begin;

-- Safety: refuse to run if Stage 1 isn't installed
do $$ begin
  if to_regprocedure('public.app_login(text,text)') is null then
    raise exception 'Stage 1 is not installed yet — run stage1-secure-login.sql first.';
  end if;
end $$;

-- 1) Move un-upgraded legacy hashes into the hidden table, then blank them
insert into public.app_credentials(user_id, legacy_hash)
  select id, password_hash from public.users where password_hash is not null
on conflict (user_id) do update
  set legacy_hash = coalesce(public.app_credentials.legacy_hash, excluded.legacy_hash);
update public.users set password_hash = null where password_hash is not null;

-- 2) Drop every existing rule on the app's tables
do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public'
             and tablename in ('users','jobs','job_items','releases','invites',
                               'job_assignments','activity','password_resets')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- 3) Make sure row security is on everywhere
alter table public.users           enable row level security;
alter table public.jobs            enable row level security;
alter table public.job_items       enable row level security;
alter table public.releases        enable row level security;
alter table public.invites         enable row level security;
alter table public.job_assignments enable row level security;
alter table public.activity        enable row level security;
alter table public.password_resets enable row level security;

-- 4) New rules ───────────────────────────────────────────────────────────────
-- jobs
create policy "ule_jobs_read"   on public.jobs for select using (public.app_can_see_job(id));
create policy "ule_jobs_insert" on public.jobs for insert with check (public.app_is_manager());
create policy "ule_jobs_update" on public.jobs for update using (public.app_is_manager()) with check (public.app_is_manager());
create policy "ule_jobs_delete" on public.jobs for delete using (public.app_is_manager());

-- job_items (BOM lines)
create policy "ule_items_read"   on public.job_items for select using (public.app_can_see_job(job_id));
create policy "ule_items_insert" on public.job_items for insert with check (public.app_is_manager());
create policy "ule_items_update" on public.job_items for update using (public.app_is_manager()) with check (public.app_is_manager());
create policy "ule_items_delete" on public.job_items for delete using (public.app_is_manager());

-- releases
create policy "ule_rel_read"   on public.releases for select using (public.app_can_see_job(job_id));
create policy "ule_rel_insert" on public.releases for insert with check (public.app_is_staff());
create policy "ule_rel_update" on public.releases for update using (public.app_is_staff()) with check (public.app_is_staff());
create policy "ule_rel_delete" on public.releases for delete using (public.app_is_staff());

-- job_assignments (who can see which job)
create policy "ule_asn_read"   on public.job_assignments for select using (public.app_is_staff() or user_id = public.app_uid());
create policy "ule_asn_insert" on public.job_assignments for insert with check (public.app_is_manager());
create policy "ule_asn_update" on public.job_assignments for update using (public.app_is_manager()) with check (public.app_is_manager());
create policy "ule_asn_delete" on public.job_assignments for delete using (public.app_is_manager());

-- activity feed (internal only)
create policy "ule_act_read"   on public.activity for select using (public.app_is_staff());
create policy "ule_act_insert" on public.activity for insert with check (public.app_is_staff());

-- users: staff see the team list; everyone sees their own row; only admins change/remove
create policy "ule_users_read"   on public.users for select using (public.app_is_staff() or id = public.app_uid());
create policy "ule_users_update" on public.users for update using (public.app_is_admin()) with check (public.app_is_admin());
create policy "ule_users_delete" on public.users for delete using (public.app_is_admin());
-- (no insert rule: new accounts are created only through app_register)

-- invites: admins only (redeeming happens inside app_register)
create policy "ule_inv_read"   on public.invites for select using (public.app_is_admin());
create policy "ule_inv_insert" on public.invites for insert with check (public.app_is_admin());
create policy "ule_inv_update" on public.invites for update using (public.app_is_admin()) with check (public.app_is_admin());
create policy "ule_inv_delete" on public.invites for delete using (public.app_is_admin());

-- password_resets: no rules = closed to browsers

-- 5) Belt and braces on the hidden tables
revoke all on public.app_credentials, public.app_sessions from anon, authenticated;
revoke execute on function public.app_new_session(uuid) from public, anon, authenticated;

commit;

-- Confirmation: lists the new rules (should be 25 rows, all starting with "ule_")
select tablename, policyname, cmd from pg_policies
 where schemaname = 'public' order by tablename, policyname;
