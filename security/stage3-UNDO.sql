-- ════════════════════════════════════════════════════════════════════════════
--  ULETrack security — UNDO Stage 3 (emergency rollback)
--  Puts the old "Allow all" rules back on every table. No data is changed.
--  Sign-ins keep working (the secure login from Stage 1 stays in place).
-- ════════════════════════════════════════════════════════════════════════════
begin;
do $$ declare r record; t text; begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public'
             and tablename in ('users','jobs','job_items','releases','invites',
                               'job_assignments','activity','password_resets')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
  foreach t in array array['users','jobs','job_items','releases','invites',
                           'job_assignments','activity','password_resets'] loop
    execute format('create policy "Allow all" on public.%I for all using (true) with check (true)', t);
  end loop;
end $$;
commit;
select 'Stage 3 undone — "Allow all" restored' as status;
