# ULETrack security upgrade — runbook

Moves ULETrack from "anyone with the public key can read or change everything"
to database-enforced, per-role access. Done in three stages. Each one is safe
to stop after.

| File | When | What it does |
|---|---|---|
| `stage1-secure-login.sql` | Step 1 | Adds secure, server-side sign-in. Changes nothing existing. |
| *(site update — already on GitHub)* | Automatic | Site uses secure sign-in once Step 1 is installed. Falls back to the old login if it isn't. |
| `stage3-lockdown.sql` | Step 3, at a quiet time | Replaces the "Allow all" rules with per-role rules. |
| `stage3-UNDO.sql` | Emergency only | Puts "Allow all" back. Data untouched; sign-ins keep working. |
| `stage1-UNDO.sql` | Emergency only | Removes the secure sign-in (run stage3-UNDO first and restore the old site). |

## Step 1 — install secure sign-in
1. Supabase → ULETrack project → **SQL Editor** → **+ New query**.
2. Paste all of `stage1-secure-login.sql` → **Run**.
3. Expect one row: `Stage 1 installed | 7 | 0`.

## Step 2 — confirm it works (2 minutes)
1. Open uletrack.com and hard refresh (**Ctrl+Shift+R**).
2. You'll see *"ULETrack has a security upgrade. Please sign in again"*. Sign in with your usual password.
3. Click **Admin**. The banner at the top must be green: **"Secure sign-in active."**
   - Red ("token is not reaching the database") → **stop. Do not run Step 3.**
4. Optional: in the SQL Editor run
   `select count(*) from app_credentials where pw_hash is not null;` — the count goes up as people sign in.

## Step 3 — lock it down (evening or weekend)
1. SQL Editor → paste all of `stage3-lockdown.sql` → **Run**.
2. Expect a list of 25 rules, all starting with `ule_`.
3. Check (a phone on cellular works as a second browser):
   - You (admin) still see every job and can log a release.
   - A customer login sees only their assigned job(s).
   - Signed out, the site shows nothing but the sign-in screen.

## If something goes wrong
Run `stage3-UNDO.sql`. Everything returns to how it worked before Step 3,
including for people already signed in. Nothing is deleted.

## What changes for people
- Everyone signs in once more after the update; usernames and passwords stay the same.
- **Forgot password** now says to contact a ULE rep. Admins reset passwords from
  the Admin panel (**Reset PW**). Emailed resets were never configured, so nothing
  that worked before is lost.
- New self-signups are view-only customers and see **no jobs** until an admin assigns one.
- Live updates arrive within ~15 seconds instead of instantly (the instant-update
  channel can't carry the sign-in token; the 15-second refresh already handles this).
- PMs and coordinators can technically read all jobs at the database level (they're
  ULE staff). The app still shows them only their assigned jobs.

## How it works (for whoever maintains this)
- Sign-in calls `app_login`, which checks the password inside the database and returns
  a random 30-day session token. Passwords are bcrypt-hashed in `app_credentials`;
  old-style hashes upgrade on first sign-in.
- The site sends the token on every request as the `x-ule-session` header (with an
  `x-client-info` fallback). Rules call `app_uid()` / `app_role()` to see who is asking.
- `app_credentials` and `app_sessions` have row security with no rules, so the API
  can never read them. `app_new_session` cannot be called from a browser.
- Tested 2026-10-08 against a local copy of this schema (Postgres 16 + PostgREST 12):
  50 database checks + 24 end-to-end browser checks, plus both undo scripts.
