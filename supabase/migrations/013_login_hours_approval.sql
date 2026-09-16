-- Migration 013: login hours and sign-in approval for admins.
--
-- Two independent gates, both only for the 'admin' role (super admins are
-- never gated, or nobody could unlock anyone):
--
--   1. Login hours   Each account may have a daily from/to window in IST.
--                    Outside it the password is refused outright, and an
--                    admin already signed in loses access the moment the
--                    window ends.
--   2. Approval      A new sign-in waits until a super admin approves it,
--                    unless that account has "auto allow" ticked. Approval
--                    is per session and lasts only as long as that day's
--                    window, because gate 1 keeps being checked.
--
-- Existing accounts and existing sessions are left working: every account
-- present when this runs gets auto_approve = true, and every live session
-- is marked approved. Untick "auto allow" per person to start gating them.
--
-- Run once in Supabase Dashboard -> SQL Editor. (schema.sql already includes this.)

-- ---------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------
alter table public.admins add column if not exists login_from time;
alter table public.admins add column if not exists login_to   time;

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'admins' and column_name = 'auto_approve') then
    alter table public.admins add column auto_approve boolean not null default false;
    -- Accounts that existed before this feature keep signing in as before.
    update public.admins set auto_approve = true;
  end if;
end $$;

-- A stable id for a session, so a super admin can approve one without ever
-- being shown its token.
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'admin_sessions' and column_name = 'id') then
    alter table public.admin_sessions add column id bigint generated always as identity;
    create unique index admin_sessions_id_idx on public.admin_sessions(id);
  end if;
end $$;

alter table public.admin_sessions add column if not exists ip text;
alter table public.admin_sessions add column if not exists approved_by bigint references public.admins(id) on delete set null;

do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'admin_sessions' and column_name = 'approved_at') then
    alter table public.admin_sessions add column approved_at timestamptz;
    -- Nobody signed in right now is thrown onto the waiting page.
    update public.admin_sessions set approved_at = now();
  end if;
end $$;

create index if not exists admin_sessions_pending_idx
  on public.admin_sessions(created_at desc) where approved_at is null;

-- ---------------------------------------------------------------------
-- Login window
-- ---------------------------------------------------------------------
-- True when this account may be signed in right now. Days are IST.
-- A window of 17:00-02:00 wraps past midnight. Super admins, and admins
-- with no window set, are always allowed.
create or replace function public._within_login_window(a public.admins)
returns boolean
language sql stable
as $$
  select case
    when a.role = 'super' then true
    when a.login_from is null or a.login_to is null then true
    when a.login_from = a.login_to then true
    when a.login_from < a.login_to
      then (now() at time zone 'Asia/Kolkata')::time >= a.login_from
       and (now() at time zone 'Asia/Kolkata')::time <  a.login_to
    else (now() at time zone 'Asia/Kolkata')::time >= a.login_from
      or  (now() at time zone 'Asia/Kolkata')::time <  a.login_to
  end;
$$;

create or replace function public._window_label(a public.admins)
returns text
language sql stable
as $$
  select case
    when a.login_from is null or a.login_to is null then null
    else to_char(a.login_from, 'HH24:MI') || ' and ' || to_char(a.login_to, 'HH24:MI')
  end;
$$;

-- ---------------------------------------------------------------------
-- Session checks
-- ---------------------------------------------------------------------
-- Token valid and account active. No login-hours or approval check, so the
-- waiting page can still ask who it is signed in as.
create or replace function public._session_admin(p_token uuid)
returns public.admins
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins;
begin
  select ad.* into a
  from public.admin_sessions s
  join public.admins ad on ad.id = s.admin_id
  where s.token = p_token and s.expires_at > now() and ad.is_active;

  if a.id is null then
    raise exception 'Session expired. Please log in again.' using errcode = '28000';
  end if;
  return a;
end $$;

-- Full gate, used by every admin RPC.
--   28000  session gone, or the login window has ended -> log in again
--   28002  signed in but still waiting for a super admin
--   42501  super admin required
create or replace function public._require_admin(p_token uuid, p_super boolean default false)
returns public.admins
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v_label text;
begin
  a := public._session_admin(p_token);

  if p_super and a.role <> 'super' then
    raise exception 'Super admin access required.' using errcode = '42501';
  end if;

  if a.role <> 'super' then
    if not public._within_login_window(a) then
      v_label := public._window_label(a);
      raise exception 'Your login hours (% IST) have ended.', v_label using errcode = '28000';
    end if;
    if not exists (select 1 from public.admin_sessions s
                   where s.token = p_token and s.approved_at is not null) then
      raise exception 'Waiting for a super admin to approve this sign-in.' using errcode = '28002';
    end if;
  end if;

  return a;
end $$;

-- ---------------------------------------------------------------------
-- Who am I (works while waiting for approval)
-- ---------------------------------------------------------------------
create or replace function public.admin_me(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v_approved boolean;
begin
  a := public._session_admin(p_token);
  select s.approved_at is not null into v_approved
  from public.admin_sessions s where s.token = p_token;

  return json_build_object(
    'username', a.username,
    'role', a.role,
    'approved', a.role = 'super' or coalesce(v_approved, false),
    'in_window', public._within_login_window(a),
    'window', public._window_label(a));
end $$;

-- ---------------------------------------------------------------------
-- Login: refuse outside the window, hold for approval otherwise
-- ---------------------------------------------------------------------
create or replace function public.admin_login(p_username text, p_password text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a        public.admins;
  s        public.admin_sessions;
  v_user   text := lower(trim(coalesce(p_username, '')));
  v_ip     text := public._request_ip();
  v_since  timestamptz;
  v_fails  int;
  v_ipfail int := 0;
  v_wait   int;
  v_label  text;
begin
  delete from public.login_attempts where created_at < now() - interval '1 day';

  select greatest(now() - interval '15 minutes',
                  coalesce(max(created_at), '-infinity'::timestamptz)) into v_since
  from public.login_attempts where username = v_user and succeeded;

  select count(*) into v_fails from public.login_attempts
  where username = v_user and not succeeded and created_at > v_since;

  if v_ip is not null then
    select count(*) into v_ipfail from public.login_attempts
    where ip = v_ip and not succeeded and created_at > now() - interval '15 minutes';
  end if;

  if v_fails >= 5 then
    select ceil(extract(epoch from (t.created_at + interval '15 minutes' - now())) / 60)::int into v_wait
    from (select created_at from public.login_attempts
          where username = v_user and not succeeded and created_at > v_since
          order by created_at desc offset 4 limit 1) t;
    return json_build_object('error',
      format('Too many failed attempts. Try again in %s minute(s).', greatest(coalesce(v_wait, 1), 1)));
  end if;
  if v_ipfail >= 20 then
    return json_build_object('error', 'Too many failed attempts from this network. Try again in 15 minutes.');
  end if;

  select * into a from public.admins where lower(username) = v_user and is_active;

  if a.id is null
     or coalesce(p_password, '') = ''
     or crypt(p_password, a.password_hash) is distinct from a.password_hash then
    insert into public.login_attempts(username, ip, succeeded) values (v_user, v_ip, false);
    return json_build_object('error', 'Invalid username or password.');
  end if;

  -- Password was right, so this is not a brute-force attempt: no attempt row
  -- is written and the failure counter is left alone.
  if not public._within_login_window(a) then
    v_label := public._window_label(a);
    perform public._audit(a, 'staff.login_refused', a.id::text,
      jsonb_build_object('username', a.username, 'window', v_label, 'ip', v_ip));
    return json_build_object('error',
      format('You can only sign in between %s IST.', v_label));
  end if;

  insert into public.login_attempts(username, ip, succeeded) values (v_user, v_ip, true);
  update public.admins set last_login_at = now() where id = a.id;
  delete from public.admin_sessions where expires_at < now();

  insert into public.admin_sessions(admin_id, ip, approved_at)
  values (a.id, v_ip, case when a.role = 'super' or a.auto_approve then now() end)
  returning * into s;

  perform public._login_ping();

  return json_build_object('token', s.token, 'username', a.username, 'role', a.role,
                           'expires_at', s.expires_at,
                           'approved', s.approved_at is not null,
                           'window', public._window_label(a));
end $$;

-- ---------------------------------------------------------------------
-- Approvals (super admin)
-- ---------------------------------------------------------------------
-- Sign-ins still waiting, oldest first. Sessions whose window has since
-- ended are not listed: approving them would achieve nothing.
create or replace function public.pending_logins(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token, true);
  select coalesce(json_agg(r order by r.created_at), '[]'::json) into v
  from (
    select s.id as session_id, ad.username, ad.role, s.ip, s.created_at,
           public._window_label(ad) as login_window
    from public.admin_sessions s
    join public.admins ad on ad.id = s.admin_id
    where s.approved_at is null
      and s.expires_at > now()
      and ad.is_active
      and public._within_login_window(ad)
    limit 50
  ) r;
  return v;
end $$;

create or replace function public.approve_login(p_token uuid, p_session_id bigint)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v_user text;
begin
  a := public._require_admin(p_token, true);

  update public.admin_sessions s
     set approved_at = now(), approved_by = a.id
   where s.id = p_session_id and s.approved_at is null and s.expires_at > now();

  if not found then
    raise exception 'That sign-in is no longer waiting.';
  end if;

  select ad.username into v_user
  from public.admin_sessions s join public.admins ad on ad.id = s.admin_id
  where s.id = p_session_id;

  perform public._audit(a, 'staff.login_approve', p_session_id::text,
    jsonb_build_object('username', v_user));
  perform public._login_ping();
  return json_build_object('username', v_user);
end $$;

-- Denying signs that device out; the person can try again.
create or replace function public.deny_login(p_token uuid, p_session_id bigint)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v_user text;
begin
  a := public._require_admin(p_token, true);

  select ad.username into v_user
  from public.admin_sessions s join public.admins ad on ad.id = s.admin_id
  where s.id = p_session_id and s.approved_at is null;
  if v_user is null then
    raise exception 'That sign-in is no longer waiting.';
  end if;

  delete from public.admin_sessions where id = p_session_id;
  perform public._audit(a, 'staff.login_deny', p_session_id::text,
    jsonb_build_object('username', v_user));
  perform public._login_ping();
  return json_build_object('username', v_user);
end $$;

-- ---------------------------------------------------------------------
-- Staff list and editor carry the new fields
-- ---------------------------------------------------------------------
create or replace function public.list_admins(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v json;
begin
  a := public._require_admin(p_token, true);
  select coalesce(json_agg(r order by r.is_active desc, lower(r.username)), '[]'::json) into v
  from (
    select ad.id, ad.username, ad.role, ad.is_active, ad.created_at, ad.last_login_at,
           to_char(ad.login_from, 'HH24:MI') as login_from,
           to_char(ad.login_to, 'HH24:MI') as login_to,
           ad.auto_approve,
           public._within_login_window(ad) as in_window,
           (select count(*) from public.admin_sessions s
             where s.admin_id = ad.id and s.expires_at > now()) as active_sessions,
           (select count(*) from public.admin_sessions s
             where s.admin_id = ad.id and s.expires_at > now() and s.approved_at is null) as waiting_sessions,
           ad.id = a.id as is_me
    from public.admins ad
  ) r;
  return v;
end $$;

-- The 6-argument version is replaced, so drop it first: leaving both would
-- make the call ambiguous.
drop function if exists public.upsert_admin(uuid, bigint, text, text, boolean, text);

create or replace function public.upsert_admin(
  p_token uuid, p_id bigint, p_username text, p_role text, p_is_active boolean,
  p_password text default null, p_login_from text default null, p_login_to text default null,
  p_auto_approve boolean default false)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a         public.admins;
  v_old     public.admins;
  v_new     public.admins;
  v_user    text := lower(trim(coalesce(p_username, '')));
  v_role    text := coalesce(p_role, 'admin');
  v_active  boolean := coalesce(p_is_active, true);
  v_pw      text := nullif(p_password, '');
  v_from    time := nullif(trim(coalesce(p_login_from, '')), '')::time;
  v_to      time := nullif(trim(coalesce(p_login_to, '')), '')::time;
  v_auto    boolean := coalesce(p_auto_approve, false);
  v_diff    jsonb;
  v_revoked int := 0;
begin
  a := public._require_admin(p_token, true);
  if v_user !~ '^[a-z0-9._-]{3,32}$' then
    raise exception 'Username must be 3-32 characters: letters, numbers, dot, dash or underscore.';
  end if;
  if v_role not in ('super', 'admin') then raise exception 'Choose a valid role.'; end if;
  if v_pw is not null and length(v_pw) < 8 then raise exception 'Password must be at least 8 characters.'; end if;
  if (v_from is null) <> (v_to is null) then
    raise exception 'Set both a start and an end time for the login hours, or leave both blank.';
  end if;
  if exists (select 1 from public.admins where lower(username) = v_user and id is distinct from p_id) then
    raise exception 'Username "%" is already taken.', v_user;
  end if;

  -- Super admins are never gated, so these fields are not stored for them.
  if v_role = 'super' then
    v_from := null; v_to := null; v_auto := true;
  end if;

  if p_id is null then
    if v_pw is null then raise exception 'Set a password for the new user.'; end if;
    insert into public.admins(username, password_hash, role, is_active, login_from, login_to, auto_approve)
    values (v_user, crypt(v_pw, gen_salt('bf')), v_role, v_active, v_from, v_to, v_auto)
    returning * into v_new;
    perform public._audit(a, 'staff.create', v_new.id::text,
      jsonb_build_object('username', v_new.username, 'role', v_new.role, 'is_active', v_new.is_active,
                         'login_from', v_from, 'login_to', v_to, 'auto_approve', v_auto));
  else
    select * into v_old from public.admins where id = p_id for update;
    if not found then raise exception 'User not found.'; end if;
    if p_id = a.id and (v_role <> 'super' or not v_active) then
      raise exception 'You cannot remove your own super admin access or deactivate yourself.';
    end if;

    update public.admins
       set username = v_user, role = v_role, is_active = v_active,
           login_from = v_from, login_to = v_to, auto_approve = v_auto,
           password_hash = case when v_pw is null then password_hash else crypt(v_pw, gen_salt('bf')) end
     where id = p_id
    returning * into v_new;

    v_diff := public._jsonb_diff(to_jsonb(v_old) - 'password_hash' - 'created_at' - 'last_login_at',
                                 to_jsonb(v_new) - 'password_hash' - 'created_at' - 'last_login_at');
    if v_pw is not null then
      v_diff := v_diff || jsonb_build_object('password', jsonb_build_array(null, 'changed'));
    end if;

    if v_pw is not null or v_old.role <> v_new.role or (v_old.is_active and not v_new.is_active) then
      delete from public.admin_sessions where admin_id = p_id and token <> p_token;
      get diagnostics v_revoked = row_count;
    end if;

    if v_diff <> '{}'::jsonb then
      perform public._audit(a, 'staff.update', p_id::text,
        jsonb_build_object('username', v_new.username, 'changes', v_diff, 'sessions_signed_out', v_revoked));
    end if;
  end if;

  return json_build_object('id', v_new.id, 'username', v_new.username,
                           'role', v_new.role, 'is_active', v_new.is_active);
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
revoke all on function public._session_admin(uuid) from public, anon, authenticated;
revoke all on function public._within_login_window(public.admins) from public, anon, authenticated;
revoke all on function public._window_label(public.admins) from public, anon, authenticated;

revoke all on function
  public.pending_logins(uuid), public.approve_login(uuid, bigint), public.deny_login(uuid, bigint),
  public.upsert_admin(uuid, bigint, text, text, boolean, text, text, text, boolean)
from public;
grant execute on function
  public.pending_logins(uuid), public.approve_login(uuid, bigint), public.deny_login(uuid, bigint),
  public.upsert_admin(uuid, bigint, text, text, boolean, text, text, text, boolean)
to anon, authenticated;

notify pgrst, 'reload schema';
