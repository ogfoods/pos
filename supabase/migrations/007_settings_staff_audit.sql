-- Migration 007: shop settings in the database, staff management, audit log.
-- Run once in Supabase Dashboard -> SQL Editor, after 006. (schema.sql already includes this.)

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
-- Shop settings: exactly one row (id = 1).
create table if not exists public.settings (
  id             int primary key default 1 check (id = 1),
  shop_name      text not null default 'My Cafe',
  shop_address   text,
  shop_phone     text,
  currency       text not null default '₹',
  upi_id         text,
  country_code   text not null default '91',
  receipt_footer text not null default 'Thank you! Visit again.',
  updated_at     timestamptz not null default now(),
  updated_by     bigint references public.admins(id) on delete set null
);
insert into public.settings(id) values (1) on conflict (id) do nothing;
alter table public.settings enable row level security;

alter table public.admins add column if not exists last_login_at timestamptz;

-- Who changed what. details holds a snapshot or {"changes": {field: [old, new]}}.
create table if not exists public.audit_log (
  id             bigint generated always as identity primary key,
  admin_id       bigint references public.admins(id) on delete set null,
  admin_username text,
  action         text not null,
  entity_id      text,
  details        jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);
create index if not exists audit_log_created_idx on public.audit_log(created_at desc);
create index if not exists audit_log_action_idx on public.audit_log(action, created_at desc);
alter table public.audit_log enable row level security;

-- ---------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------
create or replace function public._audit(p_admin public.admins, p_action text, p_entity_id text, p_details jsonb default '{}'::jsonb)
returns void
language sql security definer set search_path = public
as $$
  insert into public.audit_log(admin_id, admin_username, action, entity_id, details)
  values ((p_admin).id, (p_admin).username, p_action, p_entity_id, coalesce(p_details, '{}'::jsonb));
$$;

-- {"field": [old, new]} for every top-level key whose value differs.
create or replace function public._jsonb_diff(p_old jsonb, p_new jsonb)
returns jsonb
language sql immutable
as $$
  select coalesce(jsonb_object_agg(k, jsonb_build_array(p_old->k, p_new->k)), '{}'::jsonb)
  from (select jsonb_object_keys(coalesce(p_old, '{}'::jsonb) || coalesce(p_new, '{}'::jsonb)) as k) keys
  where (p_old->k) is distinct from (p_new->k);
$$;

-- A menu item's recipe as [{name, unit, qty}] (for audit snapshots).
create or replace function public._recipe_json(p_menu_item_id bigint)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'unit', i.unit, 'qty', mi.qty) order by lower(i.name)), '[]'::jsonb)
  from public.menu_item_ingredients mi
  join public.ingredients i on i.id = mi.ingredient_id
  where mi.menu_item_id = p_menu_item_id;
$$;

-- ---------------------------------------------------------------------
-- Auth: record last login time
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

  return json_build_object('token', s.token, 'username', a.username,
                           'role', a.role, 'expires_at', s.expires_at);
end $$;

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------
-- Public: shop name, UPI ID etc. are shown on public pages and the payment QR.
create or replace function public.get_settings()
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'shop_name', shop_name, 'shop_address', shop_address, 'shop_phone', shop_phone,
    'currency', currency, 'upi_id', upi_id, 'country_code', country_code,
    'receipt_footer', receipt_footer, 'updated_at', updated_at)
  from public.settings where id = 1;
$$;

-- Super admin. p_settings: {shop_name, shop_address, shop_phone, currency, upi_id, country_code, receipt_footer}
create or replace function public.update_settings(p_token uuid, p_settings jsonb)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a        public.admins;
  s        jsonb := coalesce(p_settings, '{}'::jsonb);
  v_old    public.settings;
  v_new    public.settings;
  v_diff   jsonb;
  v_name   text := nullif(trim(s->>'shop_name'), '');
  v_curr   text := nullif(trim(s->>'currency'), '');
  v_upi    text := nullif(trim(s->>'upi_id'), '');
  v_cc     text := coalesce(nullif(regexp_replace(coalesce(s->>'country_code', ''), '\D', '', 'g'), ''), '91');
  v_addr   text := nullif(trim(s->>'shop_address'), '');
  v_phone  text := nullif(trim(s->>'shop_phone'), '');
  v_footer text := coalesce(nullif(trim(s->>'receipt_footer'), ''), 'Thank you! Visit again.');
begin
  a := public._require_admin(p_token, true);
  if v_name is null then raise exception 'Shop name is required.'; end if;
  if length(v_name) > 80 then raise exception 'Shop name can be at most 80 characters.'; end if;
  if v_curr is null or length(v_curr) > 5 then raise exception 'Currency symbol must be 1-5 characters.'; end if;
  if v_upi is not null and v_upi !~ '^[A-Za-z0-9._-]{2,}@[A-Za-z0-9]{2,}$' then
    raise exception 'Enter a valid UPI ID, e.g. myshop@okaxis.';
  end if;
  if length(v_cc) > 4 then raise exception 'Country code must be 1-4 digits.'; end if;
  if length(coalesce(v_addr, '')) > 200 or length(v_footer) > 200 then
    raise exception 'Address and receipt footer can be at most 200 characters.';
  end if;
  if length(coalesce(v_phone, '')) > 20 then raise exception 'Shop phone can be at most 20 characters.'; end if;

  insert into public.settings(id) values (1) on conflict (id) do nothing;
  select * into v_old from public.settings where id = 1 for update;

  update public.settings
     set shop_name = v_name, shop_address = v_addr, shop_phone = v_phone, currency = v_curr,
         upi_id = v_upi, country_code = v_cc, receipt_footer = v_footer,
         updated_at = now(), updated_by = a.id
   where id = 1
  returning * into v_new;

  v_diff := public._jsonb_diff(to_jsonb(v_old) - 'id' - 'updated_at' - 'updated_by',
                               to_jsonb(v_new) - 'id' - 'updated_at' - 'updated_by');
  if v_diff <> '{}'::jsonb then
    perform public._audit(a, 'settings.update', '1', jsonb_build_object('changes', v_diff));
  end if;

  return public.get_settings();
end $$;

-- ---------------------------------------------------------------------
-- Staff (super admin)
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
           (select count(*) from public.admin_sessions s where s.admin_id = ad.id and s.expires_at > now()) as active_sessions,
           ad.id = a.id as is_me
    from public.admins ad
  ) r;
  return v;
end $$;

-- Insert when p_id is null (password required), otherwise update (blank password keeps it).
-- Changing role or password, or deactivating, signs that user out everywhere.
create or replace function public.upsert_admin(
  p_token uuid, p_id bigint, p_username text, p_role text, p_is_active boolean, p_password text default null)
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
  v_diff    jsonb;
  v_revoked int := 0;
begin
  a := public._require_admin(p_token, true);
  if v_user !~ '^[a-z0-9._-]{3,32}$' then
    raise exception 'Username must be 3-32 characters: letters, numbers, dot, dash or underscore.';
  end if;
  if v_role not in ('super', 'admin') then raise exception 'Choose a valid role.'; end if;
  if v_pw is not null and length(v_pw) < 8 then raise exception 'Password must be at least 8 characters.'; end if;
  if exists (select 1 from public.admins where lower(username) = v_user and id is distinct from p_id) then
    raise exception 'Username "%" is already taken.', v_user;
  end if;

  if p_id is null then
    if v_pw is null then raise exception 'Set a password for the new user.'; end if;
    insert into public.admins(username, password_hash, role, is_active)
    values (v_user, crypt(v_pw, gen_salt('bf')), v_role, v_active)
    returning * into v_new;
    perform public._audit(a, 'staff.create', v_new.id::text,
      jsonb_build_object('username', v_new.username, 'role', v_new.role, 'is_active', v_new.is_active));
  else
    select * into v_old from public.admins where id = p_id for update;
    if not found then raise exception 'User not found.'; end if;
    if p_id = a.id and (v_role <> 'super' or not v_active) then
      raise exception 'You cannot remove your own super admin access or deactivate yourself.';
    end if;

    update public.admins
       set username = v_user, role = v_role, is_active = v_active,
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

  return json_build_object('id', v_new.id, 'username', v_new.username, 'role', v_new.role, 'is_active', v_new.is_active);
end $$;

-- Sign a user out on all devices (your own current session is kept). Returns sessions removed.
create or replace function public.revoke_admin_sessions(p_token uuid, p_id bigint)
returns int
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v_user text; n int;
begin
  a := public._require_admin(p_token, true);
  select username into v_user from public.admins where id = p_id;
  if not found then raise exception 'User not found.'; end if;
  delete from public.admin_sessions where admin_id = p_id and token <> p_token;
  get diagnostics n = row_count;
  perform public._audit(a, 'staff.sign_out', p_id::text, jsonb_build_object('username', v_user, 'sessions', n));
  return n;
end $$;

-- Any admin: change own password. Other sessions of this user are signed out.
create or replace function public.change_my_password(p_token uuid, p_current text, p_new text)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; n int;
begin
  a := public._require_admin(p_token);
  if coalesce(p_current, '') = '' or crypt(p_current, a.password_hash) is distinct from a.password_hash then
    raise exception 'Current password is incorrect.';
  end if;
  if length(coalesce(p_new, '')) < 8 then raise exception 'New password must be at least 8 characters.'; end if;
  if p_new = p_current then raise exception 'New password must be different from the current one.'; end if;

  update public.admins set password_hash = crypt(p_new, gen_salt('bf')) where id = a.id;
  delete from public.admin_sessions where admin_id = a.id and token <> p_token;
  get diagnostics n = row_count;
  perform public._audit(a, 'staff.password', a.id::text,
    jsonb_build_object('username', a.username, 'sessions_signed_out', n));
end $$;

-- ---------------------------------------------------------------------
-- Audit log (super admin)
-- p_category: order | menu | ingredient | staff | settings (null = all)
-- ---------------------------------------------------------------------
create or replace function public.list_audit_log(
  p_token uuid, p_category text default null, p_search text default null, p_limit int default 50, p_offset int default 0)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v json;
  c text := nullif(trim(p_category), '');
  q text := nullif(trim(p_search), '');
begin
  perform public._require_admin(p_token, true);
  with f as (
    select l.id, l.admin_username, l.action, l.entity_id, l.details, l.created_at
    from public.audit_log l
    where (c is null or l.action like c || '.%')
      and (q is null or l.admin_username ilike '%' || q || '%' or l.entity_id = q
           or l.details::text ilike '%' || q || '%')
  )
  select json_build_object(
    'total_count', (select count(*) from f),
    'rows', coalesce((select json_agg(r order by r.created_at desc, r.id desc)
                      from (select * from f order by created_at desc, id desc
                            limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) r), '[]'::json))
  into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Existing functions, now audited
-- ---------------------------------------------------------------------
create or replace function public.upsert_menu_item(
  p_token uuid, p_id bigint, p_name text, p_category text, p_price numeric, p_is_active boolean,
  p_image_url text default null)
returns public.menu_items
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a     public.admins;
  m     public.menu_items;
  v_old public.menu_items;
  v_img text := nullif(trim(p_image_url), '');
  v_diff jsonb;
begin
  a := public._require_admin(p_token, true);
  if coalesce(trim(p_name), '') = '' then raise exception 'Name is required.'; end if;
  if v_img is not null and v_img !~* '^https?://' then
    raise exception 'Image URL must start with http:// or https://';
  end if;

  if p_id is null then
    insert into public.menu_items(name, category, price, is_active, image_url)
    values (trim(p_name), coalesce(nullif(trim(p_category), ''), 'General'), p_price, coalesce(p_is_active, true), v_img)
    returning * into m;
    perform public._audit(a, 'menu.create', m.id::text, to_jsonb(m) - 'id' - 'created_at');
  else
    select * into v_old from public.menu_items where id = p_id for update;
    if not found then raise exception 'Menu item not found.'; end if;
    update public.menu_items
       set name = trim(p_name),
           category = coalesce(nullif(trim(p_category), ''), 'General'),
           price = p_price,
           is_active = coalesce(p_is_active, true),
           image_url = v_img
     where id = p_id
    returning * into m;
    v_diff := public._jsonb_diff(to_jsonb(v_old) - 'created_at', to_jsonb(m) - 'created_at');
    if v_diff <> '{}'::jsonb then
      perform public._audit(a, 'menu.update', m.id::text, jsonb_build_object('name', m.name, 'changes', v_diff));
    end if;
  end if;
  return m;
end $$;

create or replace function public.delete_menu_item(p_token uuid, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; m public.menu_items;
begin
  a := public._require_admin(p_token, true);
  select * into m from public.menu_items where id = p_id;
  if not found then raise exception 'Menu item not found.'; end if;
  perform public._audit(a, 'menu.delete', p_id::text,
    (to_jsonb(m) - 'id' - 'created_at') || jsonb_build_object('recipe', public._recipe_json(p_id)));
  delete from public.menu_items where id = p_id;
end $$;

create or replace function public.mark_order_paid(p_token uuid, p_id bigint, p_method text default null)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a        public.admins;
  v_method text := nullif(lower(trim(p_method)), '');
  v_order  public.orders;
begin
  a := public._require_admin(p_token);
  if v_method is not null and v_method not in ('cash', 'upi', 'card') then
    raise exception 'Choose a valid payment method.';
  end if;

  select * into v_order from public.orders where id = p_id for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.payment_status = 'paid' then return public._order_json(p_id); end if;
  if v_order.payment_status <> 'pending' then raise exception 'Only pending orders can be marked as paid.'; end if;

  update public.orders
     set payment_status = 'paid', paid_at = now(), payment_method = coalesce(v_method, payment_method)
   where id = p_id
  returning * into v_order;

  perform public._audit(a, 'order.paid', p_id::text,
    jsonb_build_object('method', v_order.payment_method, 'total', v_order.total));
  return public._order_json(p_id);
end $$;

create or replace function public.update_order_status(p_token uuid, p_id bigint, p_status text)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v_old text;
begin
  a := public._require_admin(p_token, true);
  if p_status is null or p_status not in ('paid', 'pending', 'cancelled') then
    raise exception 'Choose a valid status: paid, pending or cancelled.';
  end if;

  select payment_status into v_old from public.orders where id = p_id for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_old = p_status then return; end if;

  update public.orders
     set payment_status = p_status,
         paid_at = case when p_status = 'paid' then coalesce(paid_at, now())
                        when p_status = 'pending' then null
                        else paid_at end
   where id = p_id;

  perform public._audit(a, 'order.status', p_id::text, jsonb_build_object('from', v_old, 'to', p_status));
end $$;

create or replace function public.delete_order(p_token uuid, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v json;
begin
  a := public._require_admin(p_token, true);
  v := public._order_json(p_id);
  if v is null then raise exception 'Order not found.'; end if;
  perform public._audit(a, 'order.delete', p_id::text, v::jsonb);
  delete from public.orders where id = p_id;
end $$;

create or replace function public.upsert_ingredient(p_token uuid, p_id bigint, p_name text, p_unit text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a      public.admins;
  v_name text := trim(p_name);
  v_old  public.ingredients;
  v_new  public.ingredients;
  v_diff jsonb;
begin
  a := public._require_admin(p_token, true);
  if coalesce(v_name, '') = '' then raise exception 'Name is required.'; end if;
  if p_unit is null or p_unit not in ('g', 'kg', 'ml', 'l', 'pcs') then
    raise exception 'Choose a valid unit.';
  end if;
  if p_id is not null then
    select * into v_old from public.ingredients where id = p_id for update;
    if not found then raise exception 'Ingredient not found.'; end if;
  end if;

  begin
    if p_id is null then
      insert into public.ingredients(name, unit) values (v_name, p_unit) returning * into v_new;
    else
      update public.ingredients set name = v_name, unit = p_unit where id = p_id returning * into v_new;
    end if;
  exception when unique_violation then
    raise exception 'An ingredient named "%" already exists.', v_name;
  end;

  if p_id is null then
    perform public._audit(a, 'ingredient.create', v_new.id::text,
      jsonb_build_object('name', v_new.name, 'unit', v_new.unit));
  else
    v_diff := public._jsonb_diff(to_jsonb(v_old) - 'created_at', to_jsonb(v_new) - 'created_at');
    if v_diff <> '{}'::jsonb then
      perform public._audit(a, 'ingredient.update', v_new.id::text,
        jsonb_build_object('name', v_new.name, 'changes', v_diff));
    end if;
  end if;

  return json_build_object('id', v_new.id);
end $$;

create or replace function public.delete_ingredient(p_token uuid, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; i public.ingredients;
begin
  a := public._require_admin(p_token, true);
  select * into i from public.ingredients where id = p_id;
  if not found then raise exception 'Ingredient not found.'; end if;
  perform public._audit(a, 'ingredient.delete', p_id::text,
    jsonb_build_object('name', i.name, 'unit', i.unit,
      'used_in', (select count(*) from public.menu_item_ingredients where ingredient_id = p_id)));
  delete from public.ingredients where id = p_id;
end $$;

-- Replaces the full recipe of a menu item. p_items: [{"ingredient_id": 1, "qty": 50}, ...]
create or replace function public.set_menu_item_ingredients(p_token uuid, p_menu_item_id bigint, p_items jsonb)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a        public.admins;
  v_items  jsonb := coalesce(p_items, '[]'::jsonb);
  v_name   text;
  v_before jsonb;
  v_after  jsonb;
begin
  a := public._require_admin(p_token, true);
  select name into v_name from public.menu_items where id = p_menu_item_id;
  if not found then raise exception 'Menu item not found.'; end if;
  if jsonb_typeof(v_items) <> 'array' then raise exception 'Invalid ingredients list.'; end if;
  if exists (
    select 1 from jsonb_array_elements(v_items) e
    where nullif(e->>'ingredient_id', '') is null
       or coalesce(nullif(e->>'qty', '')::numeric, 0) <= 0
  ) then
    raise exception 'Each ingredient needs a quantity greater than 0.';
  end if;

  v_before := public._recipe_json(p_menu_item_id);
  delete from public.menu_item_ingredients where menu_item_id = p_menu_item_id;

  insert into public.menu_item_ingredients(menu_item_id, ingredient_id, qty)
  select p_menu_item_id, i.id, sum((e->>'qty')::numeric)
  from jsonb_array_elements(v_items) e
  join public.ingredients i on i.id = (e->>'ingredient_id')::bigint
  group by i.id;

  v_after := public._recipe_json(p_menu_item_id);
  if v_before is distinct from v_after then
    perform public._audit(a, 'menu.recipe', p_menu_item_id::text,
      jsonb_build_object('name', v_name, 'from', v_before, 'to', v_after));
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
revoke all on function
  public._audit(public.admins, text, text, jsonb), public._jsonb_diff(jsonb, jsonb), public._recipe_json(bigint)
from public, anon, authenticated;

revoke all on function
  public.get_settings(), public.update_settings(uuid, jsonb),
  public.list_admins(uuid), public.upsert_admin(uuid, bigint, text, text, boolean, text),
  public.revoke_admin_sessions(uuid, bigint), public.change_my_password(uuid, text, text),
  public.list_audit_log(uuid, text, text, int, int)
from public;

grant execute on function
  public.get_settings(), public.update_settings(uuid, jsonb),
  public.list_admins(uuid), public.upsert_admin(uuid, bigint, text, text, boolean, text),
  public.revoke_admin_sessions(uuid, bigint), public.change_my_password(uuid, text, text),
  public.list_audit_log(uuid, text, text, int, int)
to anon, authenticated;

notify pgrst, 'reload schema';
