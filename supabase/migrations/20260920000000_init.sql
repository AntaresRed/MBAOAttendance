-- IncAttendance database: tables, access rules, audit log and read-only views.
--
-- Plain Postgres (15+) plus Supabase's auth.jwt() for the signed-in user's email, so it also runs on a
-- self-hosted Supabase later. Run once on an empty project, then run seed.sql.
--
-- Who can do what (enforced here, not in the web app):
--   admin    everything below, plus manage who has access; delete any lecture
--   office   read all attendance, save lectures, delete their own lectures shortly after saving
--   faculty  read attendance for the courses they teach
--   student  read their own attendance only
-- Nobody writes to the tables directly: saving and deleting go through the functions below, which check
-- the role and record every change in audit_log. audit_log can't be edited or deleted through the API.

-- ============================================================
-- Tables
-- ============================================================

create table public.students (
  reg   text primary key,
  name  text not null,
  batch text not null,
  email text unique check (email = lower(email))   -- links a student's Google account to their reg. no.
);

create table public.courses (
  name               text primary key,
  credits            numeric(3,1) not null check (credits in (1.5, 3)),
  min_attendance_pct int not null check (min_attendance_pct between 0 and 100),
  hall               text not null
);

create table public.course_faculty (
  course       text not null references public.courses(name) on update cascade on delete cascade,
  faculty_name text not null,
  primary key (course, faculty_name)
);

-- Staff and faculty allowed into the portal. Students are matched through students.email instead.
create table public.members (
  email        text primary key check (email = lower(email)),
  role         text not null check (role in ('admin', 'office', 'faculty')),
  faculty_name text,   -- faculty only: must match course_faculty.faculty_name, e.g. 'Prof. Abhipsa Pal'
  added_at     timestamptz not null default now(),
  added_by     text,
  check (role <> 'faculty' or faculty_name is not null)
);

-- Single-row settings. Change these from the Supabase SQL editor, not from the app.
create table public.app_settings (
  id                   boolean primary key default true check (id),
  allow_sample_data    boolean not null default false,   -- turn on only in the test project
  office_delete_window interval not null default interval '48 hours'
);
insert into public.app_settings default values;

create table public.lectures (
  id         uuid primary key default gen_random_uuid(),
  date       date not null,
  slot       text not null check (slot in ('08:30', '10:15', '12:00', '14:30', '16:15', '18:00')),
  course     text not null references public.courses(name) on update cascade,
  prof       text not null,
  hall       text not null,
  is_sample  boolean not null default false,
  created_at timestamptz not null default now(),
  created_by text not null
);
create index lectures_date_idx on public.lectures (date);
create index lectures_course_idx on public.lectures (course);

create table public.attendance (
  lecture_id uuid not null references public.lectures(id) on delete cascade,
  reg        text not null references public.students(reg) on update cascade,
  present    boolean not null,
  primary key (lecture_id, reg)
);
create index attendance_reg_idx on public.attendance (reg);

create table public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor_email text,
  action      text not null,
  lecture_id  uuid,
  details     jsonb not null default '{}'
);
create index audit_log_at_idx on public.audit_log (at);

-- ============================================================
-- Who is signed in
-- ============================================================

create or replace function public.current_email() returns text
language sql stable set search_path = public as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''))
$$;

create or replace function public.my_reg() returns text
language sql stable security definer set search_path = public as $$
  select reg from students where email = current_email() and current_email() <> ''
$$;

create or replace function public.my_faculty_name() returns text
language sql stable security definer set search_path = public as $$
  select faculty_name from members where email = current_email() and role = 'faculty'
$$;

-- 'admin', 'office', 'faculty', 'student', or null for anyone not given access.
create or replace function public.app_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select role from members where email = current_email()),
    (select 'student' from students where email = current_email() and current_email() <> '')
  )
$$;

-- Used by the lectures policy so it doesn't have to read attendance under RLS (which would loop).
create or replace function public.student_in_lecture(p_lecture uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from attendance where lecture_id = p_lecture and reg = my_reg())
$$;

-- What the web app needs to know about the signed-in user.
create or replace function public.my_access() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'email', current_email(),
    'role', app_role(),
    'reg', my_reg(),
    'faculty_name', my_faculty_name(),
    'allow_sample_data', s.allow_sample_data,
    'office_delete_hours', extract(epoch from s.office_delete_window) / 3600
  )
  from app_settings s
$$;

-- ============================================================
-- Read access (row-level security)
-- ============================================================

alter table public.students       enable row level security;
alter table public.courses        enable row level security;
alter table public.course_faculty enable row level security;
alter table public.members        enable row level security;
alter table public.app_settings   enable row level security;
alter table public.lectures       enable row level security;
alter table public.attendance     enable row level security;
alter table public.audit_log      enable row level security;

create policy students_read on public.students for select to authenticated using (
  (select app_role()) in ('admin', 'office', 'faculty') or reg = (select my_reg())
);
create policy courses_read on public.courses for select to authenticated using ((select app_role()) is not null);
create policy course_faculty_read on public.course_faculty for select to authenticated using ((select app_role()) is not null);
create policy members_read on public.members for select to authenticated using (
  (select app_role()) = 'admin' or email = (select current_email())
);
create policy app_settings_read on public.app_settings for select to authenticated using ((select app_role()) is not null);

create policy lectures_read on public.lectures for select to authenticated using (
  (select app_role()) in ('admin', 'office')
  or ((select app_role()) = 'faculty'
      and course in (select cf.course from public.course_faculty cf where cf.faculty_name = (select my_faculty_name())))
  or ((select app_role()) = 'student' and public.student_in_lecture(id))
);

create policy attendance_read on public.attendance for select to authenticated using (
  (select app_role()) in ('admin', 'office')
  or ((select app_role()) = 'student' and reg = (select my_reg()))
  or ((select app_role()) = 'faculty'
      and lecture_id in (select l.id from public.lectures l
                         join public.course_faculty cf on cf.course = l.course
                         where cf.faculty_name = (select my_faculty_name())))
);

create policy audit_log_read on public.audit_log for select to authenticated using ((select app_role()) = 'admin');

-- ============================================================
-- Writes (only through these functions)
-- ============================================================

-- Save one or more lectures. p_lectures is a JSON array of
--   { date, slot, course, prof, hall, roster: [reg...], absent: [reg...], is_sample }
-- Returns the new lecture ids in the same order.
create or replace function public.save_lectures(p_lectures jsonb) returns uuid[]
language plpgsql security definer set search_path = public as $$
declare
  v_role   text := coalesce(app_role(), '');
  v_email  text := current_email();
  v_allow  boolean;
  v_item   jsonb;
  v_id     uuid;
  v_ids    uuid[] := '{}';
  v_roster text[];
  v_absent text[];
  v_sample boolean;
  v_samples int := 0;
begin
  if v_role not in ('admin', 'office') then
    raise exception 'Only MBA office staff and admins can save attendance' using errcode = '42501';
  end if;
  if jsonb_typeof(p_lectures) is distinct from 'array' then
    raise exception 'Expected a list of lectures';
  end if;
  select allow_sample_data into v_allow from app_settings;

  for v_item in select value from jsonb_array_elements(p_lectures) loop
    v_sample := coalesce((v_item ->> 'is_sample')::boolean, false);
    if v_sample and not v_allow then
      raise exception 'Sample data is turned off for this database';
    end if;
    v_roster := array(select distinct jsonb_array_elements_text(coalesce(v_item -> 'roster', '[]'::jsonb)));
    v_absent := array(select distinct jsonb_array_elements_text(coalesce(v_item -> 'absent', '[]'::jsonb)));
    if cardinality(v_roster) = 0 then
      raise exception 'A lecture needs at least one student';
    end if;
    if not (v_absent <@ v_roster) then
      raise exception 'Every absent student must be on the class list';
    end if;

    insert into lectures (date, slot, course, prof, hall, is_sample, created_by)
    values ((v_item ->> 'date')::date, v_item ->> 'slot', v_item ->> 'course', v_item ->> 'prof', v_item ->> 'hall',
            v_sample, v_email)
    returning id into v_id;

    insert into attendance (lecture_id, reg, present)
    select v_id, r, not (r = any (v_absent)) from unnest(v_roster) as r;

    if v_sample then
      v_samples := v_samples + 1;
    else
      insert into audit_log (actor_email, action, lecture_id, details)
      values (v_email, 'lecture_saved', v_id, jsonb_build_object(
        'date', v_item ->> 'date', 'slot', v_item ->> 'slot', 'course', v_item ->> 'course',
        'prof', v_item ->> 'prof', 'hall', v_item ->> 'hall',
        'class_size', cardinality(v_roster), 'absent', to_jsonb(v_absent)));
    end if;
    v_ids := v_ids || v_id;
  end loop;

  if v_samples > 0 then
    insert into audit_log (actor_email, action, details)
    values (v_email, 'sample_data_saved', jsonb_build_object('lectures', v_samples));
  end if;
  return v_ids;
end $$;

-- Delete a lecture: admins any time; office staff only their own, within office_delete_window.
create or replace function public.delete_lecture(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_role   text := coalesce(app_role(), '');
  v_email  text := current_email();
  v_lec    lectures;
  v_window interval;
  v_absent text[];
begin
  select * into v_lec from lectures where id = p_id;
  if not found then
    raise exception 'Lecture not found';
  end if;
  select office_delete_window into v_window from app_settings;
  if not (v_role = 'admin'
          or (v_role = 'office' and v_lec.created_by = v_email and v_lec.created_at > now() - v_window)) then
    raise exception 'Only an admin can delete this lecture. Office staff can delete lectures they saved in the last %.', v_window
      using errcode = '42501';
  end if;

  select coalesce(array_agg(reg order by reg), '{}') into v_absent from attendance where lecture_id = p_id and not present;
  delete from lectures where id = p_id;
  insert into audit_log (actor_email, action, lecture_id, details)
  values (v_email, 'lecture_deleted', p_id, (to_jsonb(v_lec) - 'id') || jsonb_build_object('absent', to_jsonb(v_absent)));
end $$;

-- Remove all sample lectures (only where sample data is allowed, i.e. the test project).
create or replace function public.delete_sample_lectures() returns int
language plpgsql security definer set search_path = public as $$
declare
  v_role text := coalesce(app_role(), '');
  v_n    int;
begin
  if v_role not in ('admin', 'office') then
    raise exception 'Only MBA office staff and admins can remove sample data' using errcode = '42501';
  end if;
  if not (select allow_sample_data from app_settings) then
    raise exception 'Sample data is turned off for this database';
  end if;
  delete from lectures where is_sample;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into audit_log (actor_email, action, details)
    values (current_email(), 'sample_data_removed', jsonb_build_object('lectures', v_n));
  end if;
  return v_n;
end $$;

-- Admin: give someone access, or change their role.
create or replace function public.set_member(p_email text, p_role text, p_faculty_name text default null) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(p_email));
  v_old   members;
begin
  if coalesce(app_role(), '') <> 'admin' then
    raise exception 'Only admins can manage access' using errcode = '42501';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'That is not a valid email address';
  end if;
  if v_email = current_email() and p_role <> 'admin' then
    raise exception 'You can''t remove your own admin access';
  end if;
  select * into v_old from members where email = v_email;
  insert into members (email, role, faculty_name, added_by)
  values (v_email, p_role, case when p_role = 'faculty' then p_faculty_name end, current_email())
  on conflict (email) do update
    set role = excluded.role, faculty_name = excluded.faculty_name, added_at = now(), added_by = excluded.added_by;
  insert into audit_log (actor_email, action, details)
  values (current_email(), 'access_set', jsonb_build_object(
    'email', v_email, 'role', p_role, 'faculty_name', p_faculty_name,
    'previous_role', v_old.role, 'previous_faculty_name', v_old.faculty_name));
end $$;

-- Admin: remove someone's access.
create or replace function public.remove_member(p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(p_email));
  v_old   members;
begin
  if coalesce(app_role(), '') <> 'admin' then
    raise exception 'Only admins can manage access' using errcode = '42501';
  end if;
  if v_email = current_email() then
    raise exception 'You can''t remove your own access';
  end if;
  delete from members where email = v_email returning * into v_old;
  if v_old.email is not null then
    insert into audit_log (actor_email, action, details)
    values (current_email(), 'access_removed', jsonb_build_object('email', v_email, 'role', v_old.role));
  end if;
end $$;

-- Admin: link students' Google accounts. p_links is a JSON array of { reg, email }; an empty email unlinks.
create or replace function public.set_student_emails(p_links jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_item jsonb;
  v_n    int := 0;
begin
  if coalesce(app_role(), '') <> 'admin' then
    raise exception 'Only admins can link student emails' using errcode = '42501';
  end if;
  for v_item in select value from jsonb_array_elements(p_links) loop
    update students
       set email = nullif(lower(trim(v_item ->> 'email')), '')
     where reg = v_item ->> 'reg';
    if not found then
      raise exception 'Unknown reg. no. %', v_item ->> 'reg';
    end if;
    v_n := v_n + 1;
  end loop;
  insert into audit_log (actor_email, action, details)
  values (current_email(), 'student_emails_set', jsonb_build_object('count', v_n, 'links', p_links));
  return v_n;
end $$;

-- ============================================================
-- Views
-- ============================================================

-- One row per lecture with its class list and absentees; used by the web app.
-- security_invoker = the reader's own access rules apply.
create view public.lecture_records with (security_invoker = true) as
select l.id, l.date, l.slot, l.course, l.prof, l.hall, l.is_sample, l.created_at, l.created_by,
       coalesce(array_agg(a.reg order by a.reg) filter (where a.reg is not null), '{}') as roster,
       coalesce(array_agg(a.reg order by a.reg) filter (where a.present = false), '{}') as absent
from public.lectures l
left join public.attendance a on a.lecture_id = l.id
group by l.id;

-- Read-only views for other apps, in their own schema (not exposed through the Supabase API).
-- Sample data is excluded.
create schema reporting;

create view reporting.student_course_attendance as
select s.reg, s.name, s.batch, c.name as course, c.credits, c.min_attendance_pct,
       count(*)::int                                                      as classes_held,
       (count(*) filter (where a.present))::int                            as classes_attended,
       round(100.0 * count(*) filter (where a.present) / count(*), 1)      as attendance_pct,
       round(100.0 * count(*) filter (where a.present) / count(*), 1) < c.min_attendance_pct as below_limit
from public.attendance a
join public.lectures l on l.id = a.lecture_id and not l.is_sample
join public.students s on s.reg = a.reg
join public.courses c on c.name = l.course
group by s.reg, s.name, s.batch, c.name, c.credits, c.min_attendance_pct;

create view reporting.lecture_attendance as
select l.id as lecture_id, l.date, l.slot, l.course, l.prof, l.hall, a.reg, a.present
from public.lectures l
join public.attendance a on a.lecture_id = l.id
where not l.is_sample;

create view reporting.students as select reg, name, batch from public.students;
create view reporting.courses as select name, credits, min_attendance_pct, hall from public.courses;

-- ============================================================
-- Privileges
-- ============================================================

-- Supabase grants everything to its API roles by default; take that back and grant only what's needed.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

grant select on public.students, public.courses, public.course_faculty, public.members, public.app_settings,
                public.lectures, public.attendance, public.audit_log, public.lecture_records
  to authenticated;

grant execute on function
  public.current_email(), public.my_reg(), public.my_faculty_name(), public.app_role(),
  public.student_in_lecture(uuid), public.my_access(),
  public.save_lectures(jsonb), public.delete_lecture(uuid), public.delete_sample_lectures(),
  public.set_member(text, text, text), public.remove_member(text), public.set_student_emails(jsonb)
  to authenticated;

-- Read-only database login for other apps: can see the reporting views and nothing else.
-- To use it, give it a password (in the SQL editor, never in code):
--   alter role reporting_reader with login password '<a long random password>';
create role reporting_reader nologin;
grant usage on schema reporting to reporting_reader;
grant select on all tables in schema reporting to reporting_reader;
