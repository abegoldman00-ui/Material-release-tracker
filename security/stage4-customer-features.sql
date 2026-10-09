-- ════════════════════════════════════════════════════════════════════════════
--  ULETrack — STAGE 4: customer features (rep contact info + release requests)
--  Run after Stages 1 and 3. Additive only: adds 3 columns and 1 new table.
--  No existing data is changed.
--
--  • users.rep_name / rep_phone / rep_email — the ULE rep shown to each
--    customer login (set by an admin in the Admin panel).
--  • release_requests — customers ask for material from their job; staff see
--    them in a Requests inbox and turn them into releases.
--
--  Undo: stage4-UNDO.sql
-- ════════════════════════════════════════════════════════════════════════════
begin;

do $$ begin
  if to_regprocedure('public.app_uid()') is null then
    raise exception 'Stage 1 is not installed yet — run stage1-secure-login.sql first.';
  end if;
end $$;

-- 1) Rep contact info on each (customer) account
alter table public.users add column if not exists rep_name  text;
alter table public.users add column if not exists rep_phone text;
alter table public.users add column if not exists rep_email text;

-- 2) Release requests
create table if not exists public.release_requests (
  id                    uuid primary key default gen_random_uuid(),
  request_group         text not null,                 -- lines submitted together share this
  job_id                text not null references public.jobs(id) on delete cascade,
  item_id               text not null,                 -- matches job_items.item_name
  category              text,
  qty                   integer not null check (qty > 0),
  needed_by             date,                          -- customer's "needed on site" date
  note                  text,
  release_name          text,                          -- customer's release name / #
  status                text not null default 'open'
                        check (status in ('open','released','declined','cancelled')),
  requested_by          uuid references public.users(id) on delete set null,
  requested_by_username text,
  company               text,
  staff_note            text,
  handled_by_username   text,
  handled_at            timestamptz,
  created_at            timestamptz not null default now()
);
-- customer's own release name / number (added 2026-10-09; safe to re-run)
alter table public.release_requests add column if not exists release_name text;
create index if not exists release_requests_job_status on public.release_requests(job_id, status);
alter table public.release_requests enable row level security;
grant select, insert, update, delete on public.release_requests to anon, authenticated;

-- Who asked is stamped by the database (can't be faked from a browser)
create or replace function public.app_request_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.requested_by := public.app_uid();
  select u.username, u.company into new.requested_by_username, new.company
    from public.users u where u.id = new.requested_by;
  new.status := 'open';
  new.staff_note := null; new.handled_by_username := null; new.handled_at := null;
  new.created_at := now();
  return new;
end $$;

-- Customers may only cancel their own open request (nothing else changes);
-- staff updates are stamped with who handled it.
create or replace function public.app_request_before_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if not public.app_is_staff() then
    if old.status <> 'open' or new.status <> 'cancelled' then
      raise exception 'Only an open request can be cancelled';
    end if;
    new := old; new.status := 'cancelled'; new.handled_at := now();
    select username into new.handled_by_username from public.users where id = public.app_uid();
    return new;
  end if;
  -- staff: identity fields stay as the customer submitted them
  new.requested_by := old.requested_by;
  new.requested_by_username := old.requested_by_username;
  new.company := old.company;
  new.created_at := old.created_at;
  if new.status is distinct from old.status then
    select username into who from public.users where id = public.app_uid();
    new.handled_by_username := who; new.handled_at := now();
  end if;
  return new;
end $$;

drop trigger if exists trg_request_before_insert on public.release_requests;
create trigger trg_request_before_insert before insert on public.release_requests
  for each row execute function public.app_request_before_insert();
drop trigger if exists trg_request_before_update on public.release_requests;
create trigger trg_request_before_update before update on public.release_requests
  for each row execute function public.app_request_before_update();

-- Rules
drop policy if exists "ule_req_read"   on public.release_requests;
drop policy if exists "ule_req_insert" on public.release_requests;
drop policy if exists "ule_req_update" on public.release_requests;
drop policy if exists "ule_req_delete" on public.release_requests;
create policy "ule_req_read"   on public.release_requests for select
  using (public.app_can_see_job(job_id));
create policy "ule_req_insert" on public.release_requests for insert
  with check (public.app_uid() is not null and public.app_can_see_job(job_id));
create policy "ule_req_update" on public.release_requests for update
  using (public.app_is_staff() or (requested_by = public.app_uid() and status = 'open'))
  with check (public.app_is_staff() or requested_by = public.app_uid());
create policy "ule_req_delete" on public.release_requests for delete
  using (public.app_is_manager());

commit;

select 'Stage 4 installed' as status,
       (select count(*) from information_schema.columns
         where table_schema='public' and table_name='users' and column_name like 'rep_%') as rep_columns,
       (select count(*) from pg_policies where tablename='release_requests') as request_rules;
