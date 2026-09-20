-- Export side of the nightly sync to IIMPresent (docs/IIMPRESENT-SYNC.md, sections 1-6).
--
-- Three functions shape our records into the three arrays the contract asks for. They are the only
-- place the mapping lives, so the nightly job stays a transport: read, page, sign, post.
--
-- Nothing here is exposed to signed-in users: execute is granted to service_role only, which is the
-- key the nightly job runs with.

-- Optional office course codes. Until one is set, the course title is used as the course_code and the
-- receiver hand-maps it (office_course_map on their side).
alter table public.courses add column if not exists code text unique;

comment on column public.courses.code is
  'Official course code sent to IIMPresent as course_code, e.g. PGP2-MKT-401. Falls back to the course name.';

-- The last class date we have finished processing. We have no "marking finished" flag, so this is the
-- latest date that has any saved lecture, never in the future.
create or replace function public.sync_as_of() returns date
language sql stable security definer set search_path = public as $$
  select max(date) from lectures where not is_sample and date <= current_date
$$;

-- What each student is registered for, as far as our records show: a course they have been marked in.
create or replace function public.sync_enrolments(p_as_of date)
returns table (student_email text, roll_no text, course_code text, course_title text, section text, instructor text)
language sql stable security definer set search_path = public as $$
  select distinct
    s.email,
    s.reg,
    coalesce(c.code, c.name),
    c.name,
    case when c.name ~ '-A$' then 'A' when c.name ~ '-B$' then 'B' else '' end,
    (select string_agg(cf.faculty_name, ' / ' order by cf.faculty_name)
       from course_faculty cf where cf.course = c.name)
  from attendance a
  join lectures l on l.id = a.lecture_id and not l.is_sample and l.date <= p_as_of
  join students s on s.reg = a.reg
  join courses  c on c.name = l.course
  where s.email is not null
  order by 1, 3
$$;

-- One row per student per session. start_time is the scheduled slot from the timetable, which is what
-- the receiver joins on; we never store the minute a class actually began.
create or replace function public.sync_sessions(p_as_of date)
returns table (student_email text, course_code text, class_date date, start_time text,
               status text, raw_status text, counts boolean, session_no int)
language sql stable security definer set search_path = public as $$
  select s.email,
         coalesce(c.code, c.name),
         l.date,
         l.slot,
         case when a.present then 'present' else 'absent' end,
         case when a.present then 'P' else 'A' end,
         true,     -- we hold no leave rules, so every session counts toward the denominator
         row_number() over (partition by s.email, coalesce(c.code, c.name) order by l.date, l.slot)::int
  from attendance a
  join lectures l on l.id = a.lecture_id and not l.is_sample and l.date <= p_as_of
  join students s on s.reg = a.reg
  join courses  c on c.name = l.course
  where s.email is not null
  order by 1, 2, 3, 4
$$;

-- Our official numbers. The receiver displays percent as sent and never recomputes it.
create or replace function public.sync_totals(p_as_of date)
returns table (student_email text, course_code text, held int, attended int, excused int,
               percent numeric, standing text, source_updated_at timestamptz)
language sql stable security definer set search_path = public as $$
  select s.email,
         coalesce(c.code, c.name),
         count(*)::int,
         (count(*) filter (where a.present))::int,
         0,        -- we have no excused/medical/duty leave category
         round(100.0 * count(*) filter (where a.present) / count(*), 2),
         case when round(100.0 * count(*) filter (where a.present) / count(*), 2) >= c.min_attendance_pct
              then 'ok' else 'short' end,
         max(l.created_at)
  from attendance a
  join lectures l on l.id = a.lecture_id and not l.is_sample and l.date <= p_as_of
  join students s on s.reg = a.reg
  join courses  c on c.name = l.course
  where s.email is not null
  group by s.email, coalesce(c.code, c.name), c.min_attendance_pct
  order by 1, 2
$$;

-- Students who can't be sent at all, because the contract keys on the institute email address.
create or replace function public.sync_unmapped_students()
returns table (reg text, name text)
language sql stable security definer set search_path = public as $$
  select reg, name from students where email is null order by reg
$$;

revoke all on function public.sync_as_of(), public.sync_enrolments(date), public.sync_sessions(date),
                       public.sync_totals(date), public.sync_unmapped_students()
  from public, anon, authenticated;

grant execute on function public.sync_as_of(), public.sync_enrolments(date), public.sync_sessions(date),
                          public.sync_totals(date), public.sync_unmapped_students()
  to service_role;
