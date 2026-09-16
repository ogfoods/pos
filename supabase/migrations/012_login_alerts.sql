-- Migration 012: sign-in alerts for super admins.
--
-- A successful login broadcasts an empty ping on the Realtime topic
-- "admin-logins". The ping carries no data (the topic is public, same as
-- "kitchen"), so super admin screens react by calling recent_logins() with
-- their own token to fetch who signed in.
--
-- Run once in Supabase Dashboard -> SQL Editor. (schema.sql already includes this.)

-- ---------------------------------------------------------------------
-- Realtime ping
-- ---------------------------------------------------------------------
-- Never blocks or fails a login: Realtime being unavailable must not stop
-- anyone signing in.
create or replace function public._login_ping()
returns void
language plpgsql security definer set search_path = public, extensions
as $$
begin
  begin
    if to_regprocedure('realtime.send(jsonb, text, text, boolean)') is not null then
      execute 'select realtime.send($1, $2, $3, false)' using '{}'::jsonb, 'login', 'admin-logins';
    end if;
  exception when others then
    null;
  end;
end $$;

-- ---------------------------------------------------------------------
-- Who signed in (super admin only)
-- ---------------------------------------------------------------------
-- Cursor based on login_attempts.id so no sign-in is shown twice.
--   * p_after_id null  -> bootstrap: returns the current cursor, no rows
--   * p_after_id given -> successful logins newer than that id
-- Rows older than an hour are never returned, so a stale cursor kept in a
-- browser cannot replay a day of logins as fresh alerts.
create or replace function public.recent_logins(p_token uuid, p_after_id bigint default null)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token, true);

  select json_build_object(
    'server_time', now(),
    'last_id', coalesce((select max(id) from public.login_attempts where succeeded), 0),
    'rows', case when p_after_id is null then '[]'::json else coalesce((
      select json_agg(r order by r.id)
      from (
        select la.id, la.username, la.ip, la.created_at, coalesce(ad.role, 'admin') as role
        from public.login_attempts la
        left join public.admins ad on lower(ad.username) = la.username
        where la.succeeded
          and la.id > p_after_id
          and la.created_at > now() - interval '1 hour'
        order by la.id
        limit 20
      ) r), '[]'::json) end)
  into v;

  return v;
end $$;

-- ---------------------------------------------------------------------
-- Fire the ping on every successful login
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

  insert into public.login_attempts(username, ip, succeeded) values (v_user, v_ip, true);
  update public.admins set last_login_at = now() where id = a.id;
  delete from public.admin_sessions where expires_at < now();
  insert into public.admin_sessions(admin_id) values (a.id) returning * into s;

  perform public._login_ping();

  return json_build_object('token', s.token, 'username', a.username,
                           'role', a.role, 'expires_at', s.expires_at);
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
revoke all on function public._login_ping() from public, anon, authenticated;

revoke all on function public.recent_logins(uuid, bigint) from public;
grant execute on function public.recent_logins(uuid, bigint) to anon, authenticated;

notify pgrst, 'reload schema';
