-- PROTOTYPE ONLY — open access, no sign-in.
--
-- With open_prototype on, anyone who reaches the portal is treated as an admin: no Google account, no
-- members row, full access to every record. It exists so the portal can be demonstrated before sign-in
-- is set up, and it must be turned off before any real attendance is stored:
--
--   update public.app_settings set open_prototype = false;
--
-- Also turn off "Anonymous sign-ins" (Authentication -> Sign In / Providers) when you turn this off.

alter table public.app_settings add column if not exists open_prototype boolean not null default false;

comment on column public.app_settings.open_prototype is
  'PROTOTYPE ONLY: treat every visitor as an admin, with no sign-in. Never leave on with real data.';

-- Same as before, with one extra fallback at the end.
create or replace function public.app_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select role from members where email = current_email()),
    (select 'student' from students where email = current_email() and current_email() <> ''),
    (select 'admin' from app_settings where open_prototype)
  )
$$;
