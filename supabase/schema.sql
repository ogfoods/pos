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
  last_login_at timestamptz,
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
  image_url  text,
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
  payment_method text constraint orders_payment_method_check check (payment_method in ('cash', 'upi', 'card')),
  paid_at        timestamptz,
  kitchen_status text not null default 'new' constraint orders_kitchen_status_check check (kitchen_status in ('new', 'preparing', 'ready', 'served')),
  kitchen_updated_at timestamptz,
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

-- Columns added after the first release (safe on existing databases)
alter table public.menu_items add column if not exists image_url text;
alter table public.orders add column if not exists payment_method text;
alter table public.orders add column if not exists paid_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'orders_payment_method_check') then
    alter table public.orders
      add constraint orders_payment_method_check check (payment_method in ('cash', 'upi', 'card'));
  end if;
end $$;

update public.orders set paid_at = created_at where payment_status = 'paid' and paid_at is null;
create index if not exists orders_pending_idx on public.orders(created_at desc) where payment_status = 'pending';

-- Orders: kitchen status. Orders that exist when this column is first
-- added are marked served, so the kitchen does not fill with old bills.
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'orders' and column_name = 'kitchen_status') then
    alter table public.orders add column kitchen_status text not null default 'served';
    alter table public.orders alter column kitchen_status set default 'new';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'orders_kitchen_status_check') then
    alter table public.orders
      add constraint orders_kitchen_status_check check (kitchen_status in ('new', 'preparing', 'ready', 'served'));
  end if;
end $$;
alter table public.orders add column if not exists kitchen_updated_at timestamptz;
create index if not exists orders_kitchen_idx on public.orders(created_at) where kitchen_status <> 'served';

-- Login attempts (rate limit for admin_login)
create table if not exists public.login_attempts (
  id         bigint generated always as identity primary key,
  username   text not null,
  ip         text,
  succeeded  boolean not null,
  created_at timestamptz not null default now()
);
create index if not exists login_attempts_user_idx on public.login_attempts(username, created_at desc);
create index if not exists login_attempts_ip_idx on public.login_attempts(ip, created_at desc);
alter table public.login_attempts enable row level security;

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

-- One cash shift per admin at a time. Totals are frozen into `totals` at close.
create table if not exists public.shifts (
  id            bigint generated always as identity primary key,
  admin_id      bigint references public.admins(id) on delete set null,
  opened_at     timestamptz not null default now(),
  opening_cash  numeric(10,2) not null check (opening_cash >= 0),
  closed_at     timestamptz,
  closed_by     bigint references public.admins(id) on delete set null,
  counted_cash  numeric(10,2),
  expected_cash numeric(10,2),
  difference    numeric(10,2),
  totals        jsonb,
  note          text
);
create unique index if not exists shifts_one_open_idx on public.shifts(admin_id) where closed_at is null;
create index if not exists shifts_opened_idx on public.shifts(opened_at desc);
create index if not exists orders_created_by_idx on public.orders(created_by, created_at);
alter table public.shifts enable row level security;

-- Ingredients master list
create table if not exists public.ingredients (
  id         bigint generated always as identity primary key,
  name       text not null,
  unit       text not null default 'g' check (unit in ('g', 'kg', 'ml', 'l', 'pcs')),
  created_at timestamptz not null default now()
);
create unique index if not exists ingredients_name_uidx on public.ingredients (lower(name));

-- Recipe: quantity of each ingredient needed to make ONE unit of a menu item
create table if not exists public.menu_item_ingredients (
  menu_item_id  bigint not null references public.menu_items(id) on delete cascade,
  ingredient_id bigint not null references public.ingredients(id) on delete cascade,
  qty           numeric(12,3) not null check (qty > 0),
  primary key (menu_item_id, ingredient_id)
);
create index if not exists menu_item_ingredients_ing_idx on public.menu_item_ingredients(ingredient_id);

-- Snapshot of ingredients consumed by each order line, written by create_order.
-- Recipe edits later do not change history; basis for daily consumption reports.
create table if not exists public.order_item_ingredients (
  id              bigint generated always as identity primary key,
  order_id        bigint not null references public.orders(id) on delete cascade,
  order_item_id   bigint not null references public.order_items(id) on delete cascade,
  ingredient_id   bigint references public.ingredients(id) on delete set null,
  ingredient_name text not null,
  unit            text not null,
  qty             numeric(14,3) not null
);
create index if not exists order_item_ingredients_order_idx on public.order_item_ingredients(order_id);
create index if not exists orders_created_at_idx on public.orders(created_at);

alter table public.ingredients            enable row level security;
alter table public.menu_item_ingredients  enable row level security;
alter table public.order_item_ingredients enable row level security;

-- Stock is tracked only for ingredients with track_stock = true (turned on
-- automatically the first time stock is recorded), so existing menus keep
-- selling after this migration.
alter table public.ingredients add column if not exists track_stock boolean not null default false;
alter table public.ingredients add column if not exists stock numeric(14,3) not null default 0;
alter table public.ingredients add column if not exists low_stock_at numeric(14,3);

-- Shop setting: true = hide/block items whose tracked ingredients ran out;
-- false = keep selling with a warning (stock may go below zero).
alter table public.settings add column if not exists hide_out_of_stock boolean not null default true;

-- Home page details. opening_hours: {"mon": {"closed": false, "open": "07:00", "close": "22:00"}, ...} (IST)
alter table public.settings add column if not exists tagline text;
alter table public.settings add column if not exists whatsapp text;
alter table public.settings add column if not exists maps_url text;
alter table public.settings add column if not exists cover_image_url text;
alter table public.settings add column if not exists opening_hours jsonb;

-- Every stock change. qty is signed (+ in, - out); balance_after is the stock after it.
create table if not exists public.stock_movements (
  id            bigint generated always as identity primary key,
  ingredient_id bigint not null references public.ingredients(id) on delete cascade,
  kind          text not null check (kind in ('purchase', 'waste', 'adjust', 'sale', 'sale_reversal')),
  qty           numeric(14,3) not null,
  balance_after numeric(14,3) not null,
  order_id      bigint references public.orders(id) on delete set null,
  admin_id      bigint references public.admins(id) on delete set null,
  note          text,
  created_at    timestamptz not null default now()
);
create index if not exists stock_movements_ing_idx on public.stock_movements(ingredient_id, created_at desc);
create index if not exists stock_movements_order_idx on public.stock_movements(order_id);
alter table public.stock_movements enable row level security;

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

-- Client IP from the PostgREST request headers (null outside an API request).
create or replace function public._request_ip()
returns text
language sql stable
as $$
  select nullif(trim(split_part(coalesce(
    nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for', ''), ',', 1)), '');
$$;

-- Full order as JSON (used by receipts).
create or replace function public._order_json(p_id bigint)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'id', o.id, 'phone', o.phone, 'customer_name', o.customer_name, 'total', o.total,
    'payment_status', o.payment_status, 'payment_method', o.payment_method,
    'paid_at', o.paid_at, 'created_at', o.created_at, 'created_by', ad.username,
    'items', coalesce((select json_agg(json_build_object('name', oi.item_name, 'price', oi.price, 'qty', oi.qty) order by oi.id)
                         from public.order_items oi where oi.order_id = o.id), '[]'::json))
  from public.orders o
  left join public.admins ad on ad.id = o.created_by
  where o.id = p_id;
$$;

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

-- Validates opening hours and returns them in canonical form (all 7 days). null stays null.
create or replace function public._normalize_hours(p jsonb)
returns jsonb
language plpgsql immutable
as $$
declare d text; e jsonb; v jsonb := '{}'::jsonb; t text := '^([01][0-9]|2[0-3]):[0-5][0-9]$';
begin
  if p is null or jsonb_typeof(p) = 'null' then return null; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'Opening hours are invalid.'; end if;
  foreach d in array array['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'] loop
    e := p->d;
    if e is null or jsonb_typeof(e) <> 'object' or (e->'closed') = 'true'::jsonb then
      v := v || jsonb_build_object(d, jsonb_build_object('closed', true));
    else
      if coalesce(e->>'open', '') !~ t or coalesce(e->>'close', '') !~ t then
        raise exception 'Enter opening and closing times for % as HH:MM, or mark it closed.', initcap(d);
      end if;
      if e->>'open' = e->>'close' then
        raise exception 'Opening and closing times for % cannot be the same.', initcap(d);
      end if;
      v := v || jsonb_build_object(d, jsonb_build_object('closed', false, 'open', e->>'open', 'close', e->>'close'));
    end if;
  end loop;
  return v;
end $$;

create or replace function public._hide_out_of_stock()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select hide_out_of_stock from public.settings where id = 1), true);
$$;

-- Deducts the tracked ingredients an order uses (from its ingredient snapshot).
-- p_block = true raises when stock is short. Returns [{name, unit, stock}] for
-- ingredients that went below zero.
create or replace function public._stock_deduct_order(p_admin_id bigint, p_order_id bigint, p_block boolean)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare r record; v_warn jsonb := '[]'::jsonb;
begin
  perform 1 from public.ingredients
   where track_stock and id in (select ingredient_id from public.order_item_ingredients where order_id = p_order_id)
   order by id
   for update;

  for r in
    select i.id, i.name, i.unit, i.stock, sum(oii.qty) as need
    from public.order_item_ingredients oii
    join public.ingredients i on i.id = oii.ingredient_id
    where oii.order_id = p_order_id and i.track_stock
    group by i.id, i.name, i.unit, i.stock
    order by i.id
  loop
    if r.stock < r.need then
      if p_block then
        raise exception 'Not enough %: % % left, this bill needs % %.',
          r.name, trim_scale(r.stock), r.unit, trim_scale(r.need), r.unit;
      end if;
      v_warn := v_warn || jsonb_build_array(jsonb_build_object('name', r.name, 'unit', r.unit, 'stock', r.stock - r.need));
    end if;
    update public.ingredients set stock = stock - r.need where id = r.id;
    insert into public.stock_movements(ingredient_id, kind, qty, balance_after, order_id, admin_id)
    values (r.id, 'sale', -r.need, r.stock - r.need, p_order_id, p_admin_id);
  end loop;
  return v_warn;
end $$;

-- Puts back whatever an order still has deducted (net of its movements).
create or replace function public._stock_restore_order(p_admin_id bigint, p_order_id bigint)
returns void
language plpgsql security definer set search_path = public
as $$
declare r record; v_bal numeric(14,3);
begin
  perform 1 from public.ingredients
   where id in (select ingredient_id from public.stock_movements where order_id = p_order_id)
   order by id
   for update;

  for r in
    select m.ingredient_id, -sum(m.qty) as back
    from public.stock_movements m
    where m.order_id = p_order_id
    group by m.ingredient_id
    having sum(m.qty) <> 0
    order by m.ingredient_id
  loop
    update public.ingredients set stock = stock + r.back where id = r.ingredient_id returning stock into v_bal;
    insert into public.stock_movements(ingredient_id, kind, qty, balance_after, order_id, admin_id)
    values (r.ingredient_id, 'sale_reversal', r.back, v_bal, p_order_id, p_admin_id);
  end loop;
end $$;

-- Sales by one admin between two times (orders they billed).
create or replace function public._shift_totals(p_admin_id bigint, p_from timestamptz, p_to timestamptz)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'orders',          count(*) filter (where payment_status = 'paid'),
    'sales',           coalesce(sum(total) filter (where payment_status = 'paid'), 0),
    'cash',            coalesce(sum(total) filter (where payment_status = 'paid' and payment_method = 'cash'), 0),
    'upi',             coalesce(sum(total) filter (where payment_status = 'paid' and payment_method = 'upi'), 0),
    'card',            coalesce(sum(total) filter (where payment_status = 'paid' and payment_method = 'card'), 0),
    'pending_count',   count(*) filter (where payment_status = 'pending'),
    'pending_total',   coalesce(sum(total) filter (where payment_status = 'pending'), 0),
    'cancelled_count', count(*) filter (where payment_status = 'cancelled'),
    'cancelled_total', coalesce(sum(total) filter (where payment_status = 'cancelled'), 0))
  from public.orders
  where created_by = p_admin_id and created_at >= p_from and created_at < p_to;
$$;

-- Shift as JSON. Open shifts get live totals and expected cash up to now.
create or replace function public._shift_json(p_id bigint)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'id', s.id, 'admin_id', s.admin_id, 'username', ad.username,
    'opened_at', s.opened_at, 'closed_at', s.closed_at, 'closed_by', cb.username,
    'is_open', s.closed_at is null,
    'opening_cash', s.opening_cash,
    'totals', t.totals,
    'expected_cash', coalesce(s.expected_cash, s.opening_cash + (t.totals->>'cash')::numeric),
    'counted_cash', s.counted_cash, 'difference', s.difference, 'note', s.note)
  from public.shifts s
  left join public.admins ad on ad.id = s.admin_id
  left join public.admins cb on cb.id = s.closed_by
  cross join lateral (select coalesce(s.totals, public._shift_totals(s.admin_id, s.opened_at, now())) as totals) t
  where s.id = p_id;
$$;

-- Live refresh: after orders change, broadcast an empty "orders" event on
-- the public Realtime topic "kitchen". It carries no order data; kitchen
-- screens react by calling kitchen_orders() with their token. Never blocks
-- billing: skipped when Realtime is unavailable, errors are swallowed.
-- ---------------------------------------------------------------------
create or replace function public._kitchen_ping()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  begin
    if to_regprocedure('realtime.send(jsonb, text, text, boolean)') is not null then
      execute 'select realtime.send($1, $2, $3, false)' using '{}'::jsonb, 'orders', 'kitchen';
    end if;
  exception when others then
    null;
  end;
  return null;
end $$;

drop trigger if exists orders_kitchen_ping on public.orders;
create trigger orders_kitchen_ping
  after insert or delete or update of kitchen_status, payment_status on public.orders
  for each statement execute function public._kitchen_ping();

-- ---------------------------------------------------------------------
-- Auth
-- Login is rate-limited. Failures are returned as {"error": ...}
-- instead of raised, so the failed attempt row is not rolled back.
--   * 5 failures for a username within 15 minutes -> locked (reset by a success)
--   * 20 failures from one IP within 15 minutes   -> locked
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

create or replace function public.admin_logout(p_token uuid)
returns void
language sql security definer set search_path = public
as $$ delete from public.admin_sessions where token = p_token; $$;

-- Sign-in alerts: after a successful login, broadcast an empty "login" event
-- on the public Realtime topic "admin-logins". It carries no data; super
-- admin screens react by calling recent_logins() with their token. Never
-- blocks a login: skipped when Realtime is unavailable, errors are swallowed.
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

-- Super admin: who signed in. Cursor based on login_attempts.id so no
-- sign-in is shown twice.
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
    select ord.id, ord.customer_name, ord.total, ord.payment_status, ord.payment_method, ord.created_at,
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

drop function if exists public.upsert_menu_item(uuid, bigint, text, text, numeric, boolean);

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

-- ---------------------------------------------------------------------
-- Orders
-- p_payment_method: cash | card -> saved as paid; upi -> saved as pending
-- ---------------------------------------------------------------------
drop function if exists public.create_order(uuid, text, text, jsonb);

create or replace function public.create_order(
  p_token uuid, p_phone text, p_customer_name text, p_items jsonb, p_payment_method text default 'cash')
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a        public.admins;
  v_phone  text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_name   text := nullif(trim(p_customer_name), '');
  v_method text := lower(trim(coalesce(p_payment_method, 'cash')));
  v_order  public.orders;
  v_count  int;
  v_warn   jsonb;
begin
  a := public._require_admin(p_token);

  if v_phone !~ '^[0-9]{10}$' then
    raise exception 'Enter a valid 10-digit phone number.';
  end if;
  if v_method not in ('cash', 'upi', 'card') then
    raise exception 'Choose a valid payment method.';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one item.';
  end if;

  insert into public.customers(phone, name) values (v_phone, v_name)
  on conflict (phone) do update set name = coalesce(excluded.name, public.customers.name);

  insert into public.orders(phone, customer_name, created_by, payment_method, payment_status, paid_at)
  values (v_phone, coalesce(v_name, (select name from public.customers where phone = v_phone)), a.id,
          v_method,
          case when v_method = 'upi' then 'pending' else 'paid' end,
          case when v_method = 'upi' then null else now() end)
  returning * into v_order;

  insert into public.order_items(order_id, menu_item_id, item_name, price, qty)
  select v_order.id, m.id, m.name, m.price, (i->>'qty')::int
  from jsonb_array_elements(p_items) i
  join public.menu_items m on m.id = (i->>'menu_item_id')::bigint and m.is_active
  where (i->>'qty')::int > 0;

  get diagnostics v_count = row_count;
  if v_count = 0 then raise exception 'No valid items in order.'; end if;

  insert into public.order_item_ingredients(order_id, order_item_id, ingredient_id, ingredient_name, unit, qty)
  select oi.order_id, oi.id, ing.id, ing.name, ing.unit, r.qty * oi.qty
  from public.order_items oi
  join public.menu_item_ingredients r on r.menu_item_id = oi.menu_item_id
  join public.ingredients ing on ing.id = r.ingredient_id
  where oi.order_id = v_order.id;

  v_warn := public._stock_deduct_order(a.id, v_order.id, public._hide_out_of_stock());

  update public.orders
     set total = (select sum(price * qty) from public.order_items where order_id = v_order.id)
   where id = v_order.id;

  return (public._order_json(v_order.id)::jsonb || jsonb_build_object('stock_warnings', v_warn))::json;
end $$;

-- Any admin: confirm payment of a pending order. p_method optionally changes the method.
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

-- Any admin: orders awaiting payment, newest first (max 50).
create or replace function public.list_pending_orders(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token);
  select coalesce(json_agg(public._order_json(o.id) order by o.created_at desc), '[]'::json) into v
  from (select id, created_at from public.orders
        where payment_status = 'pending' order by created_at desc limit 50) o;
  return v;
end $$;

-- Any admin: one order (for receipts).
create or replace function public.get_order(p_token uuid, p_id bigint)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token);
  v := public._order_json(p_id);
  if v is null then raise exception 'Order not found.'; end if;
  return v;
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
    select o.id, o.phone, o.customer_name, o.total, o.payment_status, o.payment_method, o.paid_at, o.created_at,
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
declare a public.admins; v_old text;
begin
  a := public._require_admin(p_token, true);
  if p_status is null or p_status not in ('paid', 'pending', 'cancelled') then
    raise exception 'Choose a valid status: paid, pending or cancelled.';
  end if;

  select payment_status into v_old from public.orders where id = p_id for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_old = p_status then return; end if;

  -- Cancelling gives the ingredients back; un-cancelling takes them again.
  if p_status = 'cancelled' then
    perform public._stock_restore_order(a.id, p_id);
  elsif v_old = 'cancelled' then
    perform public._stock_deduct_order(a.id, p_id, public._hide_out_of_stock());
  end if;

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
  if (v->>'payment_status') <> 'cancelled' then
    perform public._stock_restore_order(a.id, p_id);
  end if;
  perform public._audit(a, 'order.delete', p_id::text, v::jsonb);
  delete from public.orders where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- Ingredients and recipes (super admin)
-- ---------------------------------------------------------------------
create or replace function public.list_ingredients(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token, true);
  select coalesce(json_agg(r order by lower(r.name)), '[]'::json) into v
  from (
    select i.id, i.name, i.unit, i.track_stock, i.stock, i.low_stock_at,
           (select count(*) from public.menu_item_ingredients mi where mi.ingredient_id = i.id) as used_count
    from public.ingredients i
  ) r;
  return v;
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

-- Returns {"<menu_item_id>": [{ingredient_id, name, unit, qty}, ...], ...}
create or replace function public.list_menu_recipes(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token, true);
  select coalesce(json_object_agg(t.menu_item_id, t.items), '{}'::json) into v
  from (
    select mi.menu_item_id,
           json_agg(json_build_object('ingredient_id', i.id, 'name', i.name, 'unit', i.unit, 'qty', mi.qty)
                    order by lower(i.name)) as items
    from public.menu_item_ingredients mi
    join public.ingredients i on i.id = mi.ingredient_id
    group by mi.menu_item_id
  ) t;
  return v;
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

revoke all on function
  public.list_ingredients(uuid), public.upsert_ingredient(uuid, bigint, text, text),
  public.delete_ingredient(uuid, bigint), public.list_menu_recipes(uuid),
  public.set_menu_item_ingredients(uuid, bigint, jsonb)
from public;

grant execute on function
  public.list_ingredients(uuid), public.upsert_ingredient(uuid, bigint, text, text),
  public.delete_ingredient(uuid, bigint), public.list_menu_recipes(uuid),
  public.set_menu_item_ingredients(uuid, bigint, jsonb)
to anon, authenticated;

-- ---------------------------------------------------------------------
-- Ingredient usage report (super admin). Days are IST (Asia/Kolkata).
-- ---------------------------------------------------------------------
create or replace function public.ingredient_usage(
  p_token uuid, p_from date, p_to date, p_by_day boolean default false)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_from date := coalesce(p_from, (now() at time zone 'Asia/Kolkata')::date);
  v_to   date := coalesce(p_to, coalesce(p_from, (now() at time zone 'Asia/Kolkata')::date));
  v      json;
begin
  perform public._require_admin(p_token, true);
  if v_to < v_from then raise exception 'End date must be on or after start date.'; end if;
  if v_to - v_from > 366 then raise exception 'Choose a range of up to 1 year.'; end if;

  with o as (
    select ord.id, (ord.created_at at time zone 'Asia/Kolkata')::date as day
    from public.orders ord
    where ord.payment_status <> 'cancelled'
      and ord.created_at >= (v_from::timestamp at time zone 'Asia/Kolkata')
      and ord.created_at <  ((v_to + 1)::timestamp at time zone 'Asia/Kolkata')
  ), u as (
    select case when p_by_day then o.day end as day,
           oii.ingredient_name as name, oii.unit, sum(oii.qty) as total
    from public.order_item_ingredients oii
    join o on o.id = oii.order_id
    group by 1, 2, 3
  )
  select json_build_object(
    'from', v_from,
    'to', v_to,
    'order_count', (select count(*) from o),
    'orders_with_ingredients', (select count(distinct oii.order_id)
                                  from public.order_item_ingredients oii join o on o.id = oii.order_id),
    'rows', coalesce((select json_agg(u order by u.day desc nulls last, lower(u.name)) from u), '[]'::json)
  ) into v;

  return v;
end $$;

revoke all on function public.ingredient_usage(uuid, date, date, boolean) from public;
grant execute on function public.ingredient_usage(uuid, date, date, boolean) to anon, authenticated;

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
    'receipt_footer', receipt_footer, 'hide_out_of_stock', hide_out_of_stock,
    'tagline', tagline, 'whatsapp', whatsapp, 'maps_url', maps_url,
    'cover_image_url', cover_image_url, 'opening_hours', opening_hours,
    'updated_at', updated_at)
  from public.settings where id = 1;
$$;

-- Super admin. p_settings: {shop_name, shop_address, shop_phone, currency, upi_id, country_code,
-- receipt_footer, hide_out_of_stock, tagline, whatsapp, maps_url, cover_image_url, opening_hours}.
-- hide_out_of_stock and the home page keys keep their value when the key is missing.
create or replace function public.update_settings(p_token uuid, p_settings jsonb)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a         public.admins;
  s         jsonb := coalesce(p_settings, '{}'::jsonb);
  v_old     public.settings;
  v_new     public.settings;
  v_diff    jsonb;
  v_hide    boolean;
  v_tagline text;
  v_wa      text;
  v_maps    text;
  v_cover   text;
  v_hours   jsonb;
  v_name    text := nullif(trim(s->>'shop_name'), '');
  v_curr    text := nullif(trim(s->>'currency'), '');
  v_upi     text := nullif(trim(s->>'upi_id'), '');
  v_cc      text := coalesce(nullif(regexp_replace(coalesce(s->>'country_code', ''), '\D', '', 'g'), ''), '91');
  v_addr    text := nullif(trim(s->>'shop_address'), '');
  v_phone   text := nullif(trim(s->>'shop_phone'), '');
  v_footer  text := coalesce(nullif(trim(s->>'receipt_footer'), ''), 'Thank you! Visit again.');
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

  v_hide := case when jsonb_typeof(s->'hide_out_of_stock') = 'boolean' then (s->'hide_out_of_stock')::boolean
                 else v_old.hide_out_of_stock end;
  v_tagline := case when s ? 'tagline' then nullif(trim(s->>'tagline'), '') else v_old.tagline end;
  v_wa := case when s ? 'whatsapp' then nullif(regexp_replace(coalesce(s->>'whatsapp', ''), '\D', '', 'g'), '') else v_old.whatsapp end;
  v_maps := case when s ? 'maps_url' then nullif(trim(s->>'maps_url'), '') else v_old.maps_url end;
  v_cover := case when s ? 'cover_image_url' then nullif(trim(s->>'cover_image_url'), '') else v_old.cover_image_url end;
  v_hours := case when s ? 'opening_hours' then public._normalize_hours(s->'opening_hours') else v_old.opening_hours end;

  if length(coalesce(v_tagline, '')) > 120 then raise exception 'Tagline can be at most 120 characters.'; end if;
  if v_wa is not null and v_wa !~ '^[0-9]{10,15}$' then
    raise exception 'Enter a valid WhatsApp number (10-15 digits).';
  end if;
  if v_maps is not null and (v_maps !~* '^https?://' or length(v_maps) > 500) then
    raise exception 'Google Maps link must start with https://';
  end if;
  if v_cover is not null and (v_cover !~* '^https?://' or length(v_cover) > 500) then
    raise exception 'Cover photo URL must start with https://';
  end if;

  update public.settings
     set shop_name = v_name, shop_address = v_addr, shop_phone = v_phone, currency = v_curr,
         upi_id = v_upi, country_code = v_cc, receipt_footer = v_footer, hide_out_of_stock = v_hide,
         tagline = v_tagline, whatsapp = v_wa, maps_url = v_maps, cover_image_url = v_cover,
         opening_hours = v_hours,
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
-- Shifts
-- ---------------------------------------------------------------------
-- Any admin: own open shift (with live totals) or null.
create or replace function public.current_shift(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v_id bigint;
begin
  a := public._require_admin(p_token);
  select id into v_id from public.shifts where admin_id = a.id and closed_at is null;
  if v_id is null then return null; end if;
  return public._shift_json(v_id);
end $$;

create or replace function public.open_shift(p_token uuid, p_opening_cash numeric)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v_id bigint;
begin
  a := public._require_admin(p_token);
  if p_opening_cash is null or p_opening_cash < 0 or p_opening_cash > 10000000 then
    raise exception 'Enter the opening cash in the drawer (0 or more).';
  end if;
  begin
    insert into public.shifts(admin_id, opening_cash) values (a.id, round(p_opening_cash, 2)) returning id into v_id;
  exception when unique_violation then
    raise exception 'You already have an open shift.';
  end;
  perform public._audit(a, 'shift.open', v_id::text,
    jsonb_build_object('username', a.username, 'opening_cash', round(p_opening_cash, 2)));
  return public._shift_json(v_id);
end $$;

-- Closes your open shift, or (super admin) any open shift by id.
create or replace function public.close_shift(
  p_token uuid, p_counted_cash numeric, p_note text default null, p_shift_id bigint default null)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a        public.admins;
  s        public.shifts;
  v_totals jsonb;
  v_expect numeric(10,2);
  v_note   text := nullif(trim(p_note), '');
begin
  a := public._require_admin(p_token);
  if p_shift_id is null then
    select * into s from public.shifts where admin_id = a.id and closed_at is null for update;
    if not found then raise exception 'You have no open shift.'; end if;
  else
    select * into s from public.shifts where id = p_shift_id for update;
    if not found then raise exception 'Shift not found.'; end if;
    if s.admin_id is distinct from a.id and a.role <> 'super' then
      raise exception 'Super admin access required.' using errcode = '42501';
    end if;
    if s.closed_at is not null then raise exception 'This shift is already closed.'; end if;
  end if;
  if p_counted_cash is null or p_counted_cash < 0 or p_counted_cash > 10000000 then
    raise exception 'Enter the cash counted in the drawer (0 or more).';
  end if;
  if length(coalesce(v_note, '')) > 200 then raise exception 'Note can be at most 200 characters.'; end if;

  v_totals := public._shift_totals(s.admin_id, s.opened_at, now());
  v_expect := s.opening_cash + (v_totals->>'cash')::numeric;

  update public.shifts
     set closed_at = now(), closed_by = a.id, counted_cash = round(p_counted_cash, 2),
         expected_cash = v_expect, difference = round(p_counted_cash, 2) - v_expect,
         totals = v_totals, note = v_note
   where id = s.id;

  perform public._audit(a, 'shift.close', s.id::text,
    jsonb_build_object(
      'username', (select username from public.admins where id = s.admin_id),
      'opening_cash', s.opening_cash, 'expected_cash', v_expect,
      'counted_cash', round(p_counted_cash, 2), 'difference', round(p_counted_cash, 2) - v_expect));
  return public._shift_json(s.id);
end $$;

-- Super admin: shifts opened between IST dates, newest first (max 200).
create or replace function public.list_shifts(p_token uuid, p_from date, p_to date)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token, true);
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  select coalesce(json_agg(public._shift_json(x.id) order by x.opened_at desc), '[]'::json) into v
  from (select id, opened_at from public.shifts
        where opened_at >= (p_from::timestamp at time zone 'Asia/Kolkata')
          and opened_at <  ((p_to + 1)::timestamp at time zone 'Asia/Kolkata')
        order by opened_at desc limit 200) x;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Sales report (super admin). Days and hours are IST; dated by bill time.
-- Sales, orders and average count paid bills only.
-- ---------------------------------------------------------------------
create or replace function public.sales_report(p_token uuid, p_from date, p_to date)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_from date := coalesce(p_from, (now() at time zone 'Asia/Kolkata')::date);
  v_to   date := coalesce(p_to, coalesce(p_from, (now() at time zone 'Asia/Kolkata')::date));
  v      json;
begin
  perform public._require_admin(p_token, true);
  if v_to < v_from then raise exception 'End date must be on or after start date.'; end if;
  if v_to - v_from > 366 then raise exception 'Choose a range of up to 1 year.'; end if;

  with o as (
    select ord.id, ord.total, ord.payment_status, ord.payment_method, ord.created_by,
           (ord.created_at at time zone 'Asia/Kolkata') as local_at
    from public.orders ord
    where ord.created_at >= (v_from::timestamp at time zone 'Asia/Kolkata')
      and ord.created_at <  ((v_to + 1)::timestamp at time zone 'Asia/Kolkata')
  ), p as (
    select * from o where payment_status = 'paid'
  )
  select json_build_object(
    'from', v_from,
    'to', v_to,
    'summary', (select json_build_object('orders', count(*), 'sales', coalesce(sum(total), 0),
                                         'avg', coalesce(round(avg(total), 2), 0)) from p),
    'pending', (select json_build_object('orders', count(*), 'total', coalesce(sum(total), 0))
                from o where payment_status = 'pending'),
    'cancelled', (select json_build_object('orders', count(*), 'total', coalesce(sum(total), 0))
                  from o where payment_status = 'cancelled'),
    'by_method', (select coalesce(json_agg(json_build_object('method', x.m, 'orders', x.n, 'total', x.s) order by x.s desc), '[]'::json)
                  from (select coalesce(payment_method, 'unknown') m, count(*) n, sum(total) s from p group by 1) x),
    'by_day', (select json_agg(json_build_object('day', d::date, 'orders', coalesce(x.n, 0), 'total', coalesce(x.s, 0)) order by d)
               from generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') d
               left join (select local_at::date dd, count(*) n, sum(total) s from p group by 1) x on x.dd = d::date),
    'by_hour', (select json_agg(json_build_object('hour', h, 'orders', coalesce(x.n, 0), 'total', coalesce(x.s, 0)) order by h)
                from generate_series(0, 23) h
                left join (select extract(hour from local_at)::int hr, count(*) n, sum(total) s from p group by 1) x on x.hr = h),
    'top_items', (select coalesce(json_agg(t order by t.revenue desc, t.qty desc), '[]'::json)
                  from (select oi.item_name as name, sum(oi.qty)::int as qty, sum(oi.qty * oi.price) as revenue
                        from public.order_items oi join p on p.id = oi.order_id
                        group by oi.item_name order by 3 desc, 2 desc limit 10) t),
    'by_staff', (select coalesce(json_agg(json_build_object('username', coalesce(ad.username, '—'), 'orders', x.n, 'total', x.s) order by x.s desc), '[]'::json)
                 from (select created_by, count(*) n, sum(total) s from p group by 1) x
                 left join public.admins ad on ad.id = x.created_by)
  ) into v;

  return v;
end $$;

-- ---------------------------------------------------------------------
-- Kitchen (any admin)
-- ---------------------------------------------------------------------
-- Active queue (not served, not cancelled, last 24h, oldest first) and the
-- last 10 orders served in the past 2 hours (for undo).
create or replace function public.kitchen_orders(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token);
  select json_build_object(
    'server_time', now(),
    'active', coalesce((
      select json_agg(k order by k.created_at)
      from (select o.id, o.customer_name, o.created_at, o.kitchen_status, o.kitchen_updated_at,
                   o.payment_status, o.payment_method,
                   (select json_agg(json_build_object('name', oi.item_name, 'qty', oi.qty) order by oi.id)
                      from public.order_items oi where oi.order_id = o.id) as items
            from public.orders o
            where o.kitchen_status <> 'served' and o.payment_status <> 'cancelled'
              and o.created_at > now() - interval '24 hours'
            order by o.created_at
            limit 100) k), '[]'::json),
    'served', coalesce((
      select json_agg(k order by k.kitchen_updated_at desc)
      from (select o.id, o.customer_name, o.created_at, o.kitchen_status, o.kitchen_updated_at,
                   o.payment_status, o.payment_method,
                   (select json_agg(json_build_object('name', oi.item_name, 'qty', oi.qty) order by oi.id)
                      from public.order_items oi where oi.order_id = o.id) as items
            from public.orders o
            where o.kitchen_status = 'served' and o.payment_status <> 'cancelled'
              and o.kitchen_updated_at > now() - interval '2 hours'
            order by o.kitchen_updated_at desc
            limit 10) k), '[]'::json)
  ) into v;
  return v;
end $$;

-- Move an order to new | preparing | ready | served. Audited.
create or replace function public.set_kitchen_status(p_token uuid, p_id bigint, p_status text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; o public.orders;
begin
  a := public._require_admin(p_token);
  if p_status is null or p_status not in ('new', 'preparing', 'ready', 'served') then
    raise exception 'Choose a valid kitchen status.';
  end if;
  select * into o from public.orders where id = p_id for update;
  if not found then raise exception 'Order not found.'; end if;
  if o.payment_status = 'cancelled' then raise exception 'Order #% was cancelled.', p_id; end if;

  if o.kitchen_status <> p_status then
    update public.orders set kitchen_status = p_status, kitchen_updated_at = now() where id = p_id;
    perform public._audit(a, 'kitchen.status', p_id::text, jsonb_build_object('from', o.kitchen_status, 'to', p_status));
  end if;
  return json_build_object('id', p_id, 'kitchen_status', p_status);
end $$;

-- ---------------------------------------------------------------------
-- Stock
-- ---------------------------------------------------------------------
-- Any admin: per menu item with tracked ingredients -> {status: ok|low|out, can_make, short:[...]}.
-- Items not listed have no tracked ingredients (never out of stock).
create or replace function public.menu_stock(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token);
  select json_build_object(
    'hide_out_of_stock', public._hide_out_of_stock(),
    'items', coalesce((
      select json_object_agg(x.menu_item_id, json_build_object('status', x.status, 'can_make', x.can_make, 'short', x.short))
      from (
        select r.menu_item_id,
               least(greatest(floor(min(i.stock / r.qty)), 0), 1000000)::int as can_make,
               case when min(i.stock / r.qty) < 1 then 'out'
                    when bool_or(i.low_stock_at is not null and i.stock <= i.low_stock_at) then 'low'
                    else 'ok' end as status,
               coalesce(json_agg(json_build_object('name', i.name, 'unit', i.unit, 'stock', i.stock, 'need', r.qty)
                                 order by i.stock / r.qty)
                        filter (where i.stock < r.qty or (i.low_stock_at is not null and i.stock <= i.low_stock_at)),
                        '[]'::json) as short
        from public.menu_item_ingredients r
        join public.ingredients i on i.id = r.ingredient_id
        where i.track_stock
        group by r.menu_item_id
      ) x), '{}'::json)
  ) into v;
  return v;
end $$;

-- Any admin: tracked ingredients at or below their alert level (or at/below zero).
create or replace function public.low_stock(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token);
  select coalesce(json_agg(json_build_object('id', id, 'name', name, 'unit', unit, 'stock', stock, 'low_stock_at', low_stock_at)
                           order by (stock <= 0) desc, lower(name)), '[]'::json) into v
  from public.ingredients
  where track_stock and stock <= coalesce(low_stock_at, 0);
  return v;
end $$;

-- Super admin. p_kind: purchase (+qty) | waste (-qty) | count (set stock to qty). Turns tracking on. Audited.
create or replace function public.record_stock(
  p_token uuid, p_ingredient_id bigint, p_kind text, p_qty numeric, p_note text default null)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a       public.admins;
  i       public.ingredients;
  v_new   numeric(14,3);
  v_note  text := nullif(trim(p_note), '');
begin
  a := public._require_admin(p_token, true);
  if p_kind is null or p_kind not in ('purchase', 'waste', 'count') then
    raise exception 'Choose purchase, waste or count.';
  end if;
  if p_kind = 'count' and (p_qty is null or p_qty < 0 or p_qty > 1000000000) then
    raise exception 'Enter the counted quantity (0 or more).';
  end if;
  if p_kind <> 'count' and (p_qty is null or p_qty <= 0 or p_qty > 1000000000) then
    raise exception 'Enter a quantity greater than 0.';
  end if;
  if length(coalesce(v_note, '')) > 200 then raise exception 'Note can be at most 200 characters.'; end if;

  select * into i from public.ingredients where id = p_ingredient_id for update;
  if not found then raise exception 'Ingredient not found.'; end if;

  v_new := case p_kind when 'purchase' then i.stock + p_qty when 'waste' then i.stock - p_qty else p_qty end;

  update public.ingredients set stock = v_new, track_stock = true where id = i.id;
  insert into public.stock_movements(ingredient_id, kind, qty, balance_after, admin_id, note)
  values (i.id, case p_kind when 'count' then 'adjust' else p_kind end, v_new - i.stock, v_new, a.id, v_note);

  perform public._audit(a, 'stock.' || p_kind, i.id::text,
    jsonb_build_object('name', i.name, 'unit', i.unit, 'qty', round(p_qty, 3),
                       'before', i.stock, 'after', v_new, 'note', v_note));
  return json_build_object('id', i.id, 'stock', v_new, 'track_stock', true);
end $$;

-- Super admin: turn tracking on/off and set the low stock alert level. Audited.
create or replace function public.update_stock_settings(
  p_token uuid, p_id bigint, p_track boolean, p_low_stock_at numeric default null)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v_old public.ingredients; v_new public.ingredients; v_diff jsonb;
begin
  a := public._require_admin(p_token, true);
  if p_low_stock_at is not null and (p_low_stock_at < 0 or p_low_stock_at > 1000000000) then
    raise exception 'Low stock alert must be 0 or more.';
  end if;
  select * into v_old from public.ingredients where id = p_id for update;
  if not found then raise exception 'Ingredient not found.'; end if;

  update public.ingredients
     set track_stock = coalesce(p_track, false), low_stock_at = p_low_stock_at
   where id = p_id
  returning * into v_new;

  v_diff := public._jsonb_diff(
    jsonb_build_object('track_stock', v_old.track_stock, 'low_stock_at', v_old.low_stock_at),
    jsonb_build_object('track_stock', v_new.track_stock, 'low_stock_at', v_new.low_stock_at));
  if v_diff <> '{}'::jsonb then
    perform public._audit(a, 'stock.settings', p_id::text,
      jsonb_build_object('name', v_new.name, 'unit', v_new.unit, 'changes', v_diff));
  end if;
  return json_build_object('id', p_id, 'track_stock', v_new.track_stock, 'low_stock_at', v_new.low_stock_at);
end $$;

-- Super admin: latest stock movements of one ingredient (max 200).
create or replace function public.list_stock_movements(p_token uuid, p_ingredient_id bigint, p_limit int default 50)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token, true);
  select coalesce(json_agg(r order by r.created_at desc, r.id desc), '[]'::json) into v
  from (select m.id, m.kind, m.qty, m.balance_after, m.order_id, m.note, m.created_at, ad.username
        from public.stock_movements m
        left join public.admins ad on ad.id = m.admin_id
        where m.ingredient_id = p_ingredient_id
        order by m.created_at desc, m.id desc
        limit least(greatest(coalesce(p_limit, 50), 1), 200)) r;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Public (no login): home page data. Never returns customer names,
-- phone numbers, totals or sales quantities.
-- ---------------------------------------------------------------------
-- Live kitchen board: order number, items and kitchen status of today's
-- active orders (last 12 hours, not cancelled), plus today's counts (IST).
create or replace function public.public_kitchen()
returns json
language sql stable security definer set search_path = public
as $$
  with a as (
    select o.id, o.kitchen_status, o.created_at, o.kitchen_updated_at,
           (select json_agg(json_build_object('name', oi.item_name, 'qty', oi.qty) order by oi.id)
              from public.order_items oi where oi.order_id = o.id) as items
    from public.orders o
    where o.kitchen_status in ('new', 'preparing', 'ready')
      and o.payment_status <> 'cancelled'
      and o.created_at > now() - interval '12 hours'
  ), t as (
    select count(*) as orders_today,
           count(*) filter (where kitchen_status = 'served') as served_today
    from public.orders
    where payment_status <> 'cancelled'
      and created_at >= (((now() at time zone 'Asia/Kolkata')::date)::timestamp at time zone 'Asia/Kolkata')
  )
  select json_build_object(
    'server_time', now(),
    'orders_today', (select orders_today from t),
    'served_today', (select served_today from t),
    'queued', coalesce((select json_agg(x order by x.created_at)
                        from (select * from a where kitchen_status = 'new' order by created_at limit 12) x), '[]'::json),
    'preparing', coalesce((select json_agg(x order by x.created_at)
                           from (select * from a where kitchen_status = 'preparing' order by created_at limit 12) x), '[]'::json),
    'ready', coalesce((select json_agg(x order by x.kitchen_updated_at desc nulls last)
                       from (select * from a where kitchen_status = 'ready' order by kitchen_updated_at desc nulls last limit 12) x), '[]'::json)
  );
$$;

-- Public menu: available items with price, photo and stock state (ok | low | out),
-- and up to 6 favourite item ids (most sold in the last 7 days).
create or replace function public.public_menu()
returns json
language sql stable security definer set search_path = public
as $$
  with st as (
    select r.menu_item_id,
           case when min(i.stock / r.qty) < 1 then 'out'
                when bool_or(i.low_stock_at is not null and i.stock <= i.low_stock_at) then 'low'
                else 'ok' end as status
    from public.menu_item_ingredients r
    join public.ingredients i on i.id = r.ingredient_id
    where i.track_stock
    group by r.menu_item_id
  ), fav as (
    select oi.menu_item_id, sum(oi.qty) as qty
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    join public.menu_items m on m.id = oi.menu_item_id and m.is_active
    where o.payment_status = 'paid' and o.created_at > now() - interval '7 days'
    group by oi.menu_item_id
  )
  select json_build_object(
    'items', coalesce((
      select json_agg(json_build_object('id', m.id, 'name', m.name, 'category', m.category, 'price', m.price,
                                        'image_url', m.image_url, 'stock', coalesce(st.status, 'ok'))
                      order by m.category, m.name)
      from public.menu_items m
      left join st on st.menu_item_id = m.id
      where m.is_active), '[]'::json),
    'favourites', coalesce((
      select json_agg(f.menu_item_id order by f.qty desc, f.menu_item_id)
      from (select * from fav order by qty desc, menu_item_id limit 6) f), '[]'::json)
  );
$$;

-- ---------------------------------------------------------------------
-- Permissions: only expose the intended RPCs
-- ---------------------------------------------------------------------
revoke all on function public._require_admin(uuid, boolean) from public, anon, authenticated;
revoke all on function public._request_ip(), public._order_json(bigint) from public, anon, authenticated;

revoke all on function
  public.admin_login(text, text), public.admin_logout(uuid), public.admin_me(uuid),
  public.get_orders_by_phone(text), public.list_menu(uuid, boolean),
  public.upsert_menu_item(uuid, bigint, text, text, numeric, boolean, text),
  public.delete_menu_item(uuid, bigint), public.create_order(uuid, text, text, jsonb, text),
  public.mark_order_paid(uuid, bigint, text), public.list_pending_orders(uuid), public.get_order(uuid, bigint),
  public.list_orders(uuid, text, int, int), public.update_order_status(uuid, bigint, text),
  public.delete_order(uuid, bigint)
from public;

grant execute on function
  public.admin_login(text, text), public.admin_logout(uuid), public.admin_me(uuid),
  public.get_orders_by_phone(text), public.list_menu(uuid, boolean),
  public.upsert_menu_item(uuid, bigint, text, text, numeric, boolean, text),
  public.delete_menu_item(uuid, bigint), public.create_order(uuid, text, text, jsonb, text),
  public.mark_order_paid(uuid, bigint, text), public.list_pending_orders(uuid), public.get_order(uuid, bigint),
  public.list_orders(uuid, text, int, int), public.update_order_status(uuid, bigint, text),
  public.delete_order(uuid, bigint)
to anon, authenticated;

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

revoke all on function
  public._shift_totals(bigint, timestamptz, timestamptz), public._shift_json(bigint)
from public, anon, authenticated;

revoke all on function
  public.current_shift(uuid), public.open_shift(uuid, numeric),
  public.close_shift(uuid, numeric, text, bigint), public.list_shifts(uuid, date, date),
  public.sales_report(uuid, date, date)
from public;

grant execute on function
  public.current_shift(uuid), public.open_shift(uuid, numeric),
  public.close_shift(uuid, numeric, text, bigint), public.list_shifts(uuid, date, date),
  public.sales_report(uuid, date, date)
to anon, authenticated;

revoke all on function public._kitchen_ping() from public, anon, authenticated;
revoke all on function public._login_ping() from public, anon, authenticated;

revoke all on function public.recent_logins(uuid, bigint) from public;
grant execute on function public.recent_logins(uuid, bigint) to anon, authenticated;

revoke all on function public.kitchen_orders(uuid), public.set_kitchen_status(uuid, bigint, text) from public;
grant execute on function public.kitchen_orders(uuid), public.set_kitchen_status(uuid, bigint, text) to anon, authenticated;

revoke all on function
  public._hide_out_of_stock(), public._stock_deduct_order(bigint, bigint, boolean),
  public._stock_restore_order(bigint, bigint)
from public, anon, authenticated;

revoke all on function
  public.menu_stock(uuid), public.low_stock(uuid),
  public.record_stock(uuid, bigint, text, numeric, text),
  public.update_stock_settings(uuid, bigint, boolean, numeric),
  public.list_stock_movements(uuid, bigint, int)
from public;

grant execute on function
  public.menu_stock(uuid), public.low_stock(uuid),
  public.record_stock(uuid, bigint, text, numeric, text),
  public.update_stock_settings(uuid, bigint, boolean, numeric),
  public.list_stock_movements(uuid, bigint, int)
to anon, authenticated;

revoke all on function public._normalize_hours(jsonb) from public, anon, authenticated;

revoke all on function public.public_kitchen(), public.public_menu() from public;
grant execute on function public.public_kitchen(), public.public_menu() to anon, authenticated;

-- =====================================================================
-- Create the first super admin manually (run separately, edit values).
-- After that, manage users from the Staff page in the app.
--
--   insert into public.admins(username, password_hash, role)
--   values ('owner',   crypt('ChangeMe#1', gen_salt('bf')), 'super'),
--          ('cashier', crypt('ChangeMe#2', gen_salt('bf')), 'admin');
--
--   update public.admins
--      set password_hash = crypt('NewPassword', gen_salt('bf'))
--    where username = 'cashier';
-- =====================================================================
