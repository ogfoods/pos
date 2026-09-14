-- =====================================================================
-- POS Billing - Supabase schema
-- Run this whole file once in Supabase Dashboard -> SQL Editor.
--
-- Security model:
--   * RLS is enabled on every table with NO policies, so the public
--     anon key cannot read/write tables directly.
--   * All access goes through SECURITY DEFINER functions (RPC) below.
--   * Admin passwords are stored as bcrypt hashes (pgcrypto).
--   * Login returns a session token; admin RPCs require that token.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists public.admins (
  id            bigint generated always as identity primary key,
  username      text not null unique,
  password_hash text not null,
  role          text not null default 'admin' check (role in ('super', 'admin')),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

create table if not exists public.admin_sessions (
  token      uuid primary key default gen_random_uuid(),
  admin_id   bigint not null references public.admins(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '12 hours'
);

create table if not exists public.menu_items (
  id         bigint generated always as identity primary key,
  name       text not null,
  category   text not null default 'General',
  price      numeric(10,2) not null check (price >= 0),
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.customers (
  phone      text primary key,
  name       text,
  created_at timestamptz not null default now()
);

create table if not exists public.orders (
  id             bigint generated always as identity primary key,
  phone          text not null references public.customers(phone) on update cascade,
  customer_name  text,
  total          numeric(10,2) not null default 0,
  payment_status text not null default 'paid' check (payment_status in ('paid', 'pending', 'cancelled')),
  created_by     bigint references public.admins(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index if not exists orders_phone_idx on public.orders(phone, created_at desc);

create table if not exists public.order_items (
  id           bigint generated always as identity primary key,
  order_id     bigint not null references public.orders(id) on delete cascade,
  menu_item_id bigint references public.menu_items(id) on delete set null,
  item_name    text not null,   -- snapshot, survives menu edits
  price        numeric(10,2) not null,
  qty          int not null check (qty > 0)
);
create index if not exists order_items_order_idx on public.order_items(order_id);

alter table public.admins         enable row level security;
alter table public.admin_sessions enable row level security;
alter table public.menu_items     enable row level security;
alter table public.customers      enable row level security;
alter table public.orders         enable row level security;
alter table public.order_items    enable row level security;

-- ---------------------------------------------------------------------
-- Internal helper: validate token (+ optional super requirement)
-- ---------------------------------------------------------------------
create or replace function public._require_admin(p_token uuid, p_super boolean default false)
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
  if p_super and a.role <> 'super' then
    raise exception 'Super admin access required.' using errcode = '42501';
  end if;
  return a;
end $$;

-- ---------------------------------------------------------------------
-- Auth
-- ---------------------------------------------------------------------
create or replace function public.admin_login(p_username text, p_password text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; s public.admin_sessions;
begin
  select * into a from public.admins
  where lower(username) = lower(trim(p_username)) and is_active;

  if a.id is null or a.password_hash <> crypt(p_password, a.password_hash) then
    raise exception 'Invalid username or password.' using errcode = '28P01';
  end if;

  delete from public.admin_sessions where expires_at < now();
  insert into public.admin_sessions(admin_id) values (a.id) returning * into s;

  return json_build_object('token', s.token, 'username', a.username,
                           'role', a.role, 'expires_at', s.expires_at);
end $$;

create or replace function public.admin_logout(p_token uuid)
returns void
language sql security definer set search_path = public
as $$ delete from public.admin_sessions where token = p_token; $$;

create or replace function public.admin_me(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins;
begin
  a := public._require_admin(p_token);
  return json_build_object('username', a.username, 'role', a.role);
end $$;

-- ---------------------------------------------------------------------
-- Public: customer order history by phone
-- ---------------------------------------------------------------------
create or replace function public.get_orders_by_phone(p_phone text)
returns json
language sql security definer set search_path = public
as $$
  select coalesce(json_agg(o order by o.created_at desc), '[]'::json)
  from (
    select ord.id, ord.customer_name, ord.total, ord.payment_status, ord.created_at,
           (select json_agg(json_build_object('name', oi.item_name, 'price', oi.price, 'qty', oi.qty) order by oi.id)
              from public.order_items oi where oi.order_id = ord.id) as items
    from public.orders ord
    where ord.phone = regexp_replace(p_phone, '\D', '', 'g')
      and length(regexp_replace(p_phone, '\D', '', 'g')) >= 6
    order by ord.created_at desc
    limit 100
  ) o;
$$;

-- ---------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------
create or replace function public.list_menu(p_token uuid, p_include_inactive boolean default false)
returns setof public.menu_items
language plpgsql security definer set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token, p_include_inactive);
  return query
    select * from public.menu_items
    where p_include_inactive or is_active
    order by category, name;
end $$;

create or replace function public.upsert_menu_item(
  p_token uuid, p_id bigint, p_name text, p_category text, p_price numeric, p_is_active boolean)
returns public.menu_items
language plpgsql security definer set search_path = public, extensions
as $$
declare m public.menu_items;
begin
  perform public._require_admin(p_token, true);
  if coalesce(trim(p_name), '') = '' then raise exception 'Name is required.'; end if;

  if p_id is null then
    insert into public.menu_items(name, category, price, is_active)
    values (trim(p_name), coalesce(nullif(trim(p_category), ''), 'General'), p_price, coalesce(p_is_active, true))
    returning * into m;
  else
    update public.menu_items
       set name = trim(p_name),
           category = coalesce(nullif(trim(p_category), ''), 'General'),
           price = p_price,
           is_active = coalesce(p_is_active, true)
     where id = p_id
    returning * into m;
    if m.id is null then raise exception 'Menu item not found.'; end if;
  end if;
  return m;
end $$;

create or replace function public.delete_menu_item(p_token uuid, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token, true);
  delete from public.menu_items where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- Orders
-- p_items: [{"menu_item_id": 1, "qty": 2}, ...]  (prices read from DB)
-- ---------------------------------------------------------------------
create or replace function public.create_order(
  p_token uuid, p_phone text, p_customer_name text, p_items jsonb)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a       public.admins;
  v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_name  text := nullif(trim(p_customer_name), '');
  v_order public.orders;
  v_count int;
begin
  a := public._require_admin(p_token);

  if length(v_phone) < 6 or length(v_phone) > 15 then
    raise exception 'Enter a valid phone number.';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one item.';
  end if;

  insert into public.customers(phone, name) values (v_phone, v_name)
  on conflict (phone) do update set name = coalesce(excluded.name, public.customers.name);

  insert into public.orders(phone, customer_name, created_by)
  values (v_phone, coalesce(v_name, (select name from public.customers where phone = v_phone)), a.id)
  returning * into v_order;

  insert into public.order_items(order_id, menu_item_id, item_name, price, qty)
  select v_order.id, m.id, m.name, m.price, (i->>'qty')::int
  from jsonb_array_elements(p_items) i
  join public.menu_items m on m.id = (i->>'menu_item_id')::bigint and m.is_active
  where (i->>'qty')::int > 0;

  get diagnostics v_count = row_count;
  if v_count = 0 then raise exception 'No valid items in order.'; end if;

  update public.orders
     set total = (select sum(price * qty) from public.order_items where order_id = v_order.id)
   where id = v_order.id
  returning * into v_order;

  return json_build_object('id', v_order.id, 'total', v_order.total, 'created_at', v_order.created_at);
end $$;

create or replace function public.list_orders(
  p_token uuid, p_search text default null, p_limit int default 50, p_offset int default 0)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json; q text := nullif(trim(p_search), '');
begin
  perform public._require_admin(p_token, true);
  select json_build_object(
    'total_count', (select count(*) from public.orders o
                     where q is null or o.phone like '%' || q || '%'
                        or o.customer_name ilike '%' || q || '%' or o.id::text = q),
    'rows', coalesce(json_agg(r order by r.created_at desc), '[]'::json))
  into v
  from (
    select o.id, o.phone, o.customer_name, o.total, o.payment_status, o.created_at,
           ad.username as created_by,
           (select json_agg(json_build_object('name', oi.item_name, 'price', oi.price, 'qty', oi.qty) order by oi.id)
              from public.order_items oi where oi.order_id = o.id) as items
    from public.orders o
    left join public.admins ad on ad.id = o.created_by
    where q is null or o.phone like '%' || q || '%'
       or o.customer_name ilike '%' || q || '%' or o.id::text = q
    order by o.created_at desc
    limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
  ) r;
  return v;
end $$;

create or replace function public.update_order_status(p_token uuid, p_id bigint, p_status text)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token, true);
  update public.orders set payment_status = p_status where id = p_id;
end $$;

create or replace function public.delete_order(p_token uuid, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token, true);
  delete from public.orders where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- Permissions: only expose the intended RPCs
-- ---------------------------------------------------------------------
revoke all on function public._require_admin(uuid, boolean) from public, anon, authenticated;

revoke all on function
  public.admin_login(text, text), public.admin_logout(uuid), public.admin_me(uuid),
  public.get_orders_by_phone(text), public.list_menu(uuid, boolean),
  public.upsert_menu_item(uuid, bigint, text, text, numeric, boolean),
  public.delete_menu_item(uuid, bigint), public.create_order(uuid, text, text, jsonb),
  public.list_orders(uuid, text, int, int), public.update_order_status(uuid, bigint, text),
  public.delete_order(uuid, bigint)
from public;

grant execute on function
  public.admin_login(text, text), public.admin_logout(uuid), public.admin_me(uuid),
  public.get_orders_by_phone(text), public.list_menu(uuid, boolean),
  public.upsert_menu_item(uuid, bigint, text, text, numeric, boolean),
  public.delete_menu_item(uuid, bigint), public.create_order(uuid, text, text, jsonb),
  public.list_orders(uuid, text, int, int), public.update_order_status(uuid, bigint, text),
  public.delete_order(uuid, bigint)
to anon, authenticated;

-- =====================================================================
-- Create / update admins manually (run separately, edit values):
--
--   insert into public.admins(username, password_hash, role)
--   values ('owner',   crypt('ChangeMe#1', gen_salt('bf')), 'super'),
--          ('cashier', crypt('ChangeMe#2', gen_salt('bf')), 'admin');
--
--   update public.admins
--      set password_hash = crypt('NewPassword', gen_salt('bf'))
--    where username = 'cashier';
-- =====================================================================
