-- delete_lecture refused office staff with "...saved in the last 48:00:00." Same rules; the window is now
-- written in hours ("in the last 48 hours").

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
    raise exception 'Only an admin can delete this lecture. Office staff can delete lectures they saved in the last % hours.',
      round(extract(epoch from v_window) / 3600)
      using errcode = '42501';
  end if;

  select coalesce(array_agg(reg order by reg), '{}') into v_absent from attendance where lecture_id = p_id and not present;
  delete from lectures where id = p_id;
  insert into audit_log (actor_email, action, lecture_id, details)
  values (v_email, 'lecture_deleted', p_id, (to_jsonb(v_lec) - 'id') || jsonb_build_object('absent', to_jsonb(v_absent)));
end $$;
