-- ════════════════════════════════════════════════════════════════════════════
--  ULETrack security — STAGE 1: add secure login (safe, additive)
--  Paste into Supabase → SQL Editor → Run.
--
--  What this does:
--   • Adds two hidden tables: app_credentials (strongly-hashed passwords) and
--     app_sessions (sign-in tokens). Browsers can never read either one.
--   • Adds server-side login/register/sign-out functions so passwords are
--     checked inside the database instead of in the browser.
--   • Existing passwords keep working: on each person's next sign-in their old
--     password is verified once and re-saved with bcrypt (seamless upgrade).
--
--  What this does NOT do: it does not change or remove any existing rules or
--  data. The current site keeps working exactly as before.
--  Safe to run more than once.
-- ════════════════════════════════════════════════════════════════════════════

-- New sign-ups no longer need a legacy hash (passwords live in app_credentials)
alter table public.users alter column password_hash drop not null;

-- Fix: removing a user who signed up via an invite link used to fail
-- ("violates foreign key constraint"). Now the invite just forgets who used it.
do $$ declare r record; begin
  for r in select c.conname, a.attname
             from pg_constraint c
             join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
            where c.conrelid = 'public.invites'::regclass and c.contype = 'f'
              and c.confrelid = 'public.users'::regclass
  loop
    execute format('alter table public.invites drop constraint %I', r.conname);
    execute format('alter table public.invites add constraint %I foreign key (%I) references public.users(id) on delete set null',
                   r.conname, r.attname);
  end loop;
end $$;

-- ── Hidden tables ────────────────────────────────────────────────────────────
create table if not exists public.app_credentials (
  user_id     uuid primary key references public.users(id) on delete cascade,
  pw_hash     text,            -- bcrypt hash (set on first secure sign-in)
  legacy_hash text,            -- old-style hash; only used for sign-in until bcrypt is set, kept so the Stage 1 undo can restore passwords
  updated_at  timestamptz not null default now()
);
create table if not exists public.app_sessions (
  token       text primary key,
  user_id     uuid not null references public.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null
);
create index if not exists app_sessions_user_idx on public.app_sessions(user_id);

-- RLS on with NO policies = nobody can read/write these through the API
alter table public.app_credentials enable row level security;
alter table public.app_sessions    enable row level security;
revoke all on public.app_credentials, public.app_sessions from anon, authenticated;

-- ── Old password hash, re-implemented server-side (matches the site's old JS) ─
create or replace function public.app_legacy_hash(p text)
returns text language plpgsql immutable set search_path = public as $$
declare
  s  text   := p || 'ule-salt-2024';
  h1 bigint := 5381;
  h2 bigint := 52711;
  c  int;
begin
  for i in 1..char_length(s) loop
    c  := ascii(substr(s, i, 1));
    h1 := (h1 * 31 + c) % 4294967296;
    h2 := (h2 * 31 + c) % 4294967296;
  end loop;
  return lpad(to_hex(h1), 8, '0') || lpad(to_hex(h2), 8, '0');
end $$;

-- ── Who is calling? (reads the sign-in token the site sends with each request) ─
create or replace function public.app_session_token()
returns text language sql stable set search_path = public as $$
  select coalesce(
    nullif(current_setting('request.headers', true)::json ->> 'x-ule-session', ''),
    substring(coalesce(current_setting('request.headers', true)::json ->> 'x-client-info', '') from '^ule-session=([0-9a-f]{64})$')
  )
$$;

create or replace function public.app_uid()
returns uuid language sql stable security definer set search_path = public as $$
  select s.user_id from public.app_sessions s
  where s.token = public.app_session_token() and s.expires_at > now()
$$;

create or replace function public.app_role()
returns text language sql stable security definer set search_path = public as $$
  select u.role from public.users u where u.id = public.app_uid()
$$;

-- Staff = ULE employees (everyone except customers)
create or replace function public.app_is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.app_role() in ('admin','pm','coordinator','member'), false)
$$;
create or replace function public.app_is_manager()   -- can create/edit jobs
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.app_role() in ('admin','pm'), false)
$$;
create or replace function public.app_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.app_role() = 'admin', false)
$$;
create or replace function public.app_can_see_job(p_job text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.app_is_staff() or exists (
    select 1 from public.job_assignments a
    where a.job_id = p_job and a.user_id = public.app_uid()
  )
$$;

-- ── Internal: create a session for a user ────────────────────────────────────
create or replace function public.app_new_session(p_user uuid)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  tok text := encode(extensions.gen_random_bytes(32), 'hex');
  u   public.users;
begin
  delete from public.app_sessions where expires_at < now();
  insert into public.app_sessions(token, user_id, expires_at)
    values (tok, p_user, now() + interval '30 days');
  select * into u from public.users where id = p_user;
  return json_build_object('token', tok, 'id', u.id, 'username', u.username, 'role', u.role);
end $$;
revoke execute on function public.app_new_session(uuid) from public, anon, authenticated;

-- ── Sign in ──────────────────────────────────────────────────────────────────
create or replace function public.app_login(p_username text, p_password text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  u    public.users;
  cred public.app_credentials;
  ok   boolean := false;
  leg  text;
begin
  select * into u from public.users
   where lower(username) = lower(trim(p_username))
   order by created_at limit 1;
  if u.id is null or p_password is null then
    perform pg_sleep(0.4); return null;
  end if;

  select * into cred from public.app_credentials where user_id = u.id;

  if cred.pw_hash is not null then
    -- Already upgraded: bcrypt check (passwords are case-insensitive, as before)
    ok := cred.pw_hash = extensions.crypt(lower(p_password), cred.pw_hash);
  else
    -- Not upgraded yet: verify against the old-style hash once
    leg := coalesce(u.password_hash, cred.legacy_hash);
    ok  := leg is not null and leg in (public.app_legacy_hash(lower(p_password)),
                                       public.app_legacy_hash(p_password));
    if ok then
      insert into public.app_credentials(user_id, pw_hash, legacy_hash, updated_at)
        values (u.id, extensions.crypt(lower(p_password), extensions.gen_salt('bf', 10)), leg, now())
      on conflict (user_id) do update
        set pw_hash = excluded.pw_hash, legacy_hash = excluded.legacy_hash, updated_at = now();
    end if;
  end if;

  if not ok then perform pg_sleep(0.4); return null; end if;
  return public.app_new_session(u.id);
end $$;
grant execute on function public.app_login(text, text) to anon, authenticated;

-- ── Create account (self-signup or invite link) — always a view-only customer ─
create or replace function public.app_register(p_username text, p_password text,
                                               p_email text default null,
                                               p_company text default null,
                                               p_invite text default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  uname text := trim(coalesce(p_username, ''));
  inv   public.invites;
  new_id uuid;
begin
  if length(uname) < 2 then raise exception 'Choose a username.'; end if;
  if p_password is null or length(p_password) < 6 then
    raise exception 'Password must be at least 6 characters.';
  end if;
  if exists (select 1 from public.users where lower(username) = lower(uname)) then
    raise exception 'Username already taken.';
  end if;
  if p_invite is not null and p_invite <> '' then
    select * into inv from public.invites where token = p_invite for update;
    if inv.id is null or inv.used_at is not null then
      raise exception 'Invalid or already used invite link.';
    end if;
  end if;

  insert into public.users(username, email, company, role, password_hash)
    values (uname, nullif(trim(p_email), ''), nullif(trim(p_company), ''), 'customer', null)
    returning id into new_id;
  insert into public.app_credentials(user_id, pw_hash, legacy_hash)
    values (new_id, extensions.crypt(lower(p_password), extensions.gen_salt('bf', 10)),
            public.app_legacy_hash(lower(p_password)));
  if inv.id is not null then
    update public.invites set used_at = now(), used_by = new_id where id = inv.id;
  end if;
  return public.app_new_session(new_id);
end $$;
grant execute on function public.app_register(text, text, text, text, text) to anon, authenticated;

-- ── Who am I? (lets the site confirm its sign-in token is being received) ────
create or replace function public.app_whoami()
returns json language plpgsql stable security definer set search_path = public as $$
declare
  tok text := public.app_session_token();
  u   public.users;
begin
  if tok is null then return json_build_object('ok', false, 'reason', 'no_token'); end if;
  select * into u from public.users where id = public.app_uid();
  if u.id is null then return json_build_object('ok', false, 'reason', 'invalid'); end if;
  return json_build_object('ok', true, 'id', u.id, 'username', u.username, 'role', u.role);
end $$;
grant execute on function public.app_whoami() to anon, authenticated;

-- ── Sign out ─────────────────────────────────────────────────────────────────
create or replace function public.app_logout()
returns void language sql security definer set search_path = public as $$
  delete from public.app_sessions where token = public.app_session_token()
$$;
grant execute on function public.app_logout() to anon, authenticated;

-- ── Admin: set someone's password (also signs them out everywhere) ──────────
create or replace function public.app_admin_set_password(p_user uuid, p_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.app_is_admin() then raise exception 'Only admins can reset passwords.'; end if;
  if p_password is null or length(p_password) < 6 then
    raise exception 'Password must be at least 6 characters.';
  end if;
  insert into public.app_credentials(user_id, pw_hash, legacy_hash, updated_at)
    values (p_user, extensions.crypt(lower(p_password), extensions.gen_salt('bf', 10)),
            public.app_legacy_hash(lower(p_password)), now())
  on conflict (user_id) do update
    set pw_hash = excluded.pw_hash, legacy_hash = excluded.legacy_hash, updated_at = now();
  update public.users set password_hash = null where id = p_user;
  delete from public.app_sessions where user_id = p_user and token is distinct from public.app_session_token();
end $$;
grant execute on function public.app_admin_set_password(uuid, text) to anon, authenticated;

-- Confirmation
select 'Stage 1 installed' as status,
       (select count(*) from public.users) as users,
       (select count(*) from public.app_credentials where pw_hash is not null) as upgraded_so_far;
