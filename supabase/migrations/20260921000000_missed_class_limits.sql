-- Attendance standing by classes missed, matching the portal:
--   3-credit course:   up to 4 missed = within, exactly 5 = on the limit, 6 or more = below
--   1.5-credit course: up to 1 missed = within, exactly 2 = on the limit, 3 or more = below
--
-- Updates the two places the database reports a standing:
--   - the nightly IIMPresent sync's totals.standing: within -> ok, on the limit -> watch, below -> short
--   - reporting.student_course_attendance for other apps: below_limit now follows the rule above,
--     and two columns are added at the end, classes_missed and standing.

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
         case
           when count(*) filter (where not a.present) > case when c.credits = 1.5 then 2 else 5 end then 'short'
           when count(*) filter (where not a.present) = case when c.credits = 1.5 then 2 else 5 end then 'watch'
           else 'ok'
         end,
         max(l.created_at)
  from attendance a
  join lectures l on l.id = a.lecture_id and not l.is_sample and l.date <= p_as_of
  join students s on s.reg = a.reg
  join courses  c on c.name = l.course
  where s.email is not null
  group by s.email, coalesce(c.code, c.name), c.credits
  order by 1, 2
$$;

create or replace view reporting.student_course_attendance as
select s.reg, s.name, s.batch, c.name as course, c.credits, c.min_attendance_pct,
       count(*)::int                                                  as classes_held,
       (count(*) filter (where a.present))::int                        as classes_attended,
       round(100.0 * count(*) filter (where a.present) / count(*), 1)  as attendance_pct,
       count(*) filter (where not a.present) > case when c.credits = 1.5 then 2 else 5 end as below_limit,
       (count(*) filter (where not a.present))::int                    as classes_missed,
       case
         when count(*) filter (where not a.present) > case when c.credits = 1.5 then 2 else 5 end then 'below'
         when count(*) filter (where not a.present) = case when c.credits = 1.5 then 2 else 5 end then 'on_limit'
         else 'within'
       end                                                             as standing
from public.attendance a
join public.lectures l on l.id = a.lecture_id and not l.is_sample
join public.students s on s.reg = a.reg
join public.courses c on c.name = l.course
group by s.reg, s.name, s.batch, c.name, c.credits, c.min_attendance_pct;
