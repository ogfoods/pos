-- Migration 006: payment method + pending UPI flow, receipts, order status
-- validation, login rate limit (and null-password login fix).
-- Run once in Supabase Dashboard -> SQL Editor. (schema.sql already includes this.)

-- ---------------------------------------------------------------------
-- Orders: payment method and paid time
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Login attempts (rate limit)
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Auth: rate-limited login. Failures are returned as {"error": ...}
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
  delete from public.admin_sessions where expires_at < now();
  insert into public.admin_sessions(admin_id) values (a.id) returning * into s;

  return json_build_object('token', s.token, 'username', a.username,
                           'role', a.role, 'expires_at', s.expires_at);
end $$;

-- ---------------------------------------------------------------------
-- Public order history: include payment method
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

  update public.orders
     set total = (select sum(price * qty) from public.order_items where order_id = v_order.id)
   where id = v_order.id;

  return public._order_json(v_order.id);
end $$;

-- Any admin: confirm payment of a pending order. p_method optionally changes the method.
create or replace function public.mark_order_paid(p_token uuid, p_id bigint, p_method text default null)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_method text := nullif(lower(trim(p_method)), '');
  v_status text;
begin
  perform public._require_admin(p_token);
  if v_method is not null and v_method not in ('cash', 'upi', 'card') then
    raise exception 'Choose a valid payment method.';
  end if;

  select payment_status into v_status from public.orders where id = p_id for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_status = 'paid' then return public._order_json(p_id); end if;
  if v_status <> 'pending' then raise exception 'Only pending orders can be marked as paid.'; end if;

  update public.orders
     set payment_status = 'paid', paid_at = now(), payment_method = coalesce(v_method, payment_method)
   where id = p_id;

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
begin
  perform public._require_admin(p_token, true);
  if p_status is null or p_status not in ('paid', 'pending', 'cancelled') then
    raise exception 'Choose a valid status: paid, pending or cancelled.';
  end if;

  update public.orders
     set payment_status = p_status,
         paid_at = case when p_status = 'paid' then coalesce(paid_at, now())
                        when p_status = 'pending' then null
                        else paid_at end
   where id = p_id;
  if not found then raise exception 'Order not found.'; end if;
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
revoke all on function public._request_ip(), public._order_json(bigint) from public, anon, authenticated;

revoke all on function
  public.create_order(uuid, text, text, jsonb, text), public.mark_order_paid(uuid, bigint, text),
  public.list_pending_orders(uuid), public.get_order(uuid, bigint)
from public;

grant execute on function
  public.create_order(uuid, text, text, jsonb, text), public.mark_order_paid(uuid, bigint, text),
  public.list_pending_orders(uuid), public.get_order(uuid, bigint)
to anon, authenticated;

notify pgrst, 'reload schema';
