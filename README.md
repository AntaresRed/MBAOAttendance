# IncAttendance

Lecture attendance portal for the MBA programme. Staff enter only the absent students; everyone else is
marked present, and each lecture can be downloaded as an Excel sheet. The dashboard tracks every student
against their courses' attendance limits, counted in classes missed:

| Course | Within the limit | On the limit | Below the limit |
|---|---|---|---|
| 3 credits (20 classes) | 0–4 missed | exactly 5 | 6 or more |
| 1.5 credits (10 classes) | 0–1 missed | exactly 2 | 3 or more |

## What's in this repository

| Path | What it is |
|---|---|
| `index.html` | The whole web app: pages, styles, the Term-V timetable and the student list |
| `config.js` | Connection settings for the online database (empty = local mode) |
| `supabase/migrations/20260920000000_init.sql` | Database tables, access rules, audit log and read-only views |
| `supabase/seed.sql` | Students, courses and course faculty, generated from `index.html` |
| `scripts/generate_seed.py` | Regenerates `supabase/seed.sql` after the student list or courses change |

## Two modes

- **Local mode** (`config.js` left empty): records are saved only in the browser that entered them. Useful for
  trying the app, not for real use.
- **Online mode** (`config.js` filled in): records live in a Supabase (Postgres) database. People sign in
  with their college Google account and see only what their role allows.

| Role | Can do |
|---|---|
| Admin | Everything, plus decide who has access. Can delete any lecture. |
| MBA office | Take attendance, see all attendance, delete lectures they saved in the last 48 hours |
| Faculty | See attendance for the courses they teach |
| Student | See only their own attendance, per course |

These rules are enforced by the database (row-level security), not just hidden in the page, so they
can't be bypassed by editing the web app. Saving and deleting go through database functions that check
the role and write every change to an audit log that nobody can edit through the app.

## Setting up the online version

These steps should be done by the college's named owner (IT staff or a faculty coordinator), using
college-owned accounts, not a student's personal account.

### 1. Create two Supabase projects

At [supabase.com](https://supabase.com), create an organisation for the college, then two projects:

- `incattendance-test`: for development and testing with sample data. Student developers work here.
- `incattendance-live`: real attendance. Only the college owner has access to its Supabase dashboard.

Choose the **South Asia (Mumbai)** region for both so the data stays in India. The free plan is fine for
the test project. For the live project, use the Pro plan: free projects pause after a week without
activity and have no automatic backups.

### 2. Create the database

In each project, open **SQL Editor** and run, in order:

1. the whole of `supabase/migrations/20260920000000_init.sql`
2. the whole of `supabase/seed.sql`
3. the first admin (use the owner's college email, in lowercase):

   ```sql
   insert into public.members (email, role) values ('owner@college.edu', 'admin');
   ```

4. **Test project only**, to allow the "Load sample data" button:

   ```sql
   update public.app_settings set allow_sample_data = true;
   ```

### 3. Turn on Google sign-in

1. In [Google Cloud Console](https://console.cloud.google.com), under the college's Google account, create
   an OAuth client ID of type **Web application**.
   - If the college uses Google Workspace, set the OAuth consent screen's user type to **Internal**, so
     only college accounts can sign in at all.
   - Add the redirect URI shown in Supabase under **Authentication → Sign In / Providers → Google**
     (it looks like `https://<project-ref>.supabase.co/auth/v1/callback`).
2. In Supabase, **Authentication → Sign In / Providers → Google**: enable it and paste the client ID and
   secret.
3. In Supabase, **Authentication → URL Configuration**: set **Site URL** to the portal's web address, and
   add the same address under **Redirect URLs**.

Signing in with Google alone gives no access: the database only lets in people added on the Access page
(staff and faculty) or students whose email has been linked to their reg. no.

### 4. Connect the web app

In Supabase, **Project Settings → API Keys**, copy the project URL and the **anon / publishable** key into
`config.js`. The publishable key is meant to be public; the database rules protect the data. **Never** put
the `service_role` / secret key in `config.js` or anywhere in this repository.

Use a separate copy of `config.js` for the test and live deployments.

### 5. Put the web app online

`index.html` and `config.js` are static files, so any static host works: Cloudflare Pages, Netlify,
Vercel or GitHub Pages. Connect the host to this repository's `main` branch so that only reviewed code is
published.

### 6. Give people access

Sign in as the admin and open **Access**:

- **Staff and faculty:** add each person's college email with their role. For faculty, pick which
  professor they are; they'll see the courses that professor teaches.
- **Student emails:** paste one line per student, `reg. no., email`, then **Save emails**.

## Letting another app read the data

Other apps get read-only access through a separate database login, `reporting_reader`, which can read
only these views (sample data excluded):

| View | Contents |
|---|---|
| `reporting.student_course_attendance` | Per student and course: classes held, attended, missed, %, below limit, standing (`within` / `on_limit` / `below`) |
| `reporting.lecture_attendance` | Every lecture with each student's present/absent |
| `reporting.students` | Reg. no., name, batch |
| `reporting.courses` | Course, credits, minimum attendance, hall |

To turn it on, run this in the SQL Editor with a long random password (never commit the password):

```sql
alter role reporting_reader with login password '<long random password>';
```

The other app then connects with a normal Postgres connection string (Supabase: **Connect** button,
session pooler), using `reporting_reader` as the user. To cut its access, run
`alter role reporting_reader nologin;`.

## Nightly sync to IIMPresent

`sync/send-attendance.mjs` sends our attendance to IIMPresent every night, following
[docs/IIMPRESENT-SYNC.md](docs/IIMPRESENT-SYNC.md) sections 1–6. It needs Node 18 or newer and no packages.

What it does: reads our records through the `sync_*` database functions, checks every row, splits them
into pages of at most 500 rows (enrolments first, then sessions, then totals), signs each page with
HMAC-SHA256 and posts them one at a time, retrying only on receiver faults.

```bash
cp sync/.env.example sync/.env      # then fill it in
node --env-file=sync/.env sync/send-attendance.mjs --out ./out   # build pages, post nothing
node --env-file=sync/.env sync/send-attendance.mjs               # dry run against the endpoint
node --env-file=sync/.env sync/send-attendance.mjs --live        # send for real
```

Batches are `dry_run: true` unless you pass `--live` (or set `DRY_RUN=false`), so the receiver checks
them and writes nothing.

Run it nightly after the day's marking is done, e.g. at 03:00 with cron:

```
0 3 * * * cd /srv/incattendance && node --env-file=sync/.env sync/send-attendance.mjs --live >> /var/log/iimpresent-sync.log 2>&1
```

On Windows, use Task Scheduler with the same command. The job exits with code 1 and an explanation if
anything goes wrong, so a failed run is visible to whatever runs it.

**Before the first live run, the office must provide:**

| Needed | Why |
|---|---|
| Every student's institute email | The contract identifies students by email; our reg. numbers can't be sent on their own. Link them on the Access page. Students without an email are skipped and reported in the run summary. |
| Course codes (optional) | `courses.code`, e.g. `PGP2-MKT-401`. Until set, the course title is sent as `course_code` and IIMPresent maps it by hand. |
| The endpoint and shared secret | From the IIMPresent maintainer, out of band. They go in `sync/.env`, never in this repository. |

**What our records can't express yet** (these are limits of the attendance system, not of the job):

- Only `present` and `absent`. There is no excused / medical / duty leave, so every session is sent with
  `counts: true` and `excused: 0`.
- No `not_held` (cancelled classes) and no `unmarked`: a class nobody marked produces no rows at all, so
  IIMPresent will see fewer sittings than its timetable predicts and report a schedule disagreement.
- No `rescheduled` flag, and a class moved to an unusual hour can't be stored at its real time: our
  database accepts only the six printed slots. `session_no` is sent, which is what IIMPresent uses to
  pair sessions exactly.
- `as_of` is the latest date that has any saved lecture. We have no "the day's marking is finished" flag,
  so a day that is still being marked will look finished.
- `standing` follows the missed-class rule above: within the limit is `ok`, on the limit is `watch`, below
  the limit is `short`.

## Changing the student list or courses

The student list and timetable live in `index.html` (`ROSTER_TEXT`, `COURSES`, `WEEKLY`,
`DATED_SESSIONS`). After changing them:

```bash
python scripts/generate_seed.py
```

then run the new `supabase/seed.sql` in the SQL Editor. Existing rows are updated, not duplicated.

## Rules for future database changes

- Add changes as new files in `supabase/migrations/` (never edit one that has already been run), and run
  them on the test project first.
- Supabase gives its API roles full access to new tables by default. Every new table needs
  `alter table ... enable row level security;`, its own policies, and
  `revoke all on <table> from anon, authenticated;` before granting only what's needed.

## Moving to the college's own server later

Supabase can run on the college's own server with Docker ("self-hosted Supabase"), with the same API, so
the web app only needs a new URL and key in `config.js`. To move:

1. Set up self-hosted Supabase on the server.
2. Run the files in `supabase/migrations/` there.
3. Copy the data across with `pg_dump` / `pg_restore` (tables in the `public` schema).
4. Update `config.js`, and the Google sign-in redirect addresses, to point at the new server.

The database code is plain Postgres except for `auth.jwt()`, which reads the signed-in user's email and is
provided by Supabase's sign-in service.

## Running it locally

Open `index.html` through any local web server, for example:

```bash
python -m http.server 8765
```

then go to <http://localhost:8765>. With `config.js` empty it runs in local mode.
