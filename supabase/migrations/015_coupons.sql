-- Migration 015: coupons.
--
-- Super admins create coupons on the Coupons page. At the payment step of a
-- new bill the cashier can enter one code; the discount is worked out here,
-- in the database, both for the preview (check_coupon) and again when the
-- bill is saved (create_order), so the page cannot be edited to cheat.
--
-- Kinds
--   percent  value% off the eligible items, optionally capped by max_discount
--   flat     value off the eligible items (never more than they cost)
--   bogo     buy buy_qty, get get_qty free: in every group of buy+get
--            eligible units, the cheapest get_qty are free
-- applies_to 'all' covers the whole bill; 'items' only the listed menu
-- items and/or categories.
--
-- Rules: active switch, valid_from / valid_to (IST dates, inclusive),
-- minimum bill (whole bill before discount), total uses, uses per customer.
-- A coupon with a per-customer limit needs the customer's phone number.
-- Cancelled bills do not count as uses. One coupon per bill.
--
-- orders.total stays the amount actually charged, so sales, shifts and the
-- awaiting-payment list all show the discounted figure. orders.subtotal is
-- the amount before discount.
--
-- Run once in Supabase Dashboard -> SQL Editor. (schema.sql already includes this.)

create table if not exists public.coupons (
  id                 bigint generated always as identity primary key,
  code               text not null,
  description        text,
  kind               text not null check (kind in ('percent', 'flat', 'bogo')),
  value              numeric(10,2) not null default 0 check (value >= 0),
  max_discount       numeric(10,2) check (max_discount > 0),
  min_bill           numeric(10,2) not null default 0 check (min_bill >= 0),
  buy_qty            int check (buy_qty > 0),
  get_qty            int check (get_qty > 0),
  applies_to         text not null default 'all' check (applies_to in ('all', 'items')),
  item_ids           bigint[] not null default '{}',
  categories         text[] not null default '{}',
  valid_from         date,
  valid_to           date,
  usage_limit        int check (usage_limit > 0),
  per_customer_limit int check (per_customer_limit > 0),
  is_active          boolean not null default true,
  created_by         bigint references public.admins(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint coupons_dates_check check (valid_from is null or valid_to is null or valid_to >= valid_from)
);
create unique index if not exists coupons_code_idx on public.coupons(upper(code));
alter table public.coupons enable row level security;

alter table public.orders add column if not exists subtotal    numeric(10,2);
alter table public.orders add column if not exists discount    numeric(10,2) not null default 0;
alter table public.orders add column if not exists coupon_id   bigint references public.coupons(id) on delete set null;
alter table public.orders add column if not exists coupon_code text;   -- snapshot, survives coupon deletes
update public.orders set subtotal = total where subtotal is null;
create index if not exists orders_coupon_idx on public.orders(coupon_id, phone) where coupon_id is not null;

-- Bill lines for a coupon: one row per active menu item, with whether the
-- coupon covers it. p_items is [{menu_item_id, qty}], as sent by the bill.
create or replace function public._coupon_lines(c public.coupons, p_items jsonb)
returns table (menu_item_id bigint, price numeric, qty int, eligible boolean)
language sql stable security definer set search_path = public
as $$
  select m.id, m.price, q.qty,
         (c).applies_to = 'all' or m.id = any((c).item_ids) or m.category = any((c).categories)
  from (select (i->>'menu_item_id')::bigint as id, sum((i->>'qty')::int)::int as qty
          from jsonb_array_elements(p_items) i
         where (i->>'qty')::int > 0
         group by 1) q
  join public.menu_items m on m.id = q.id and m.is_active;
$$;

-- Checks a coupon against a bill and works out the discount. Raises a
-- message the cashier can read when the coupon cannot be used.
-- p_lock serialises concurrent saves so usage limits hold.
create or replace function public._coupon_quote(p_code text, p_items jsonb, p_phone text, p_lock boolean default false)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  c        public.coupons;
  v_code   text := upper(trim(coalesce(p_code, '')));
  v_today  date := (now() at time zone 'Asia/Kolkata')::date;
  v_cur    text := coalesce((select currency from public.settings where id = 1), '₹');
  v_sub    numeric;
  v_elig   numeric;
  v_units  int;
  v_free   int;
  v_disc   numeric;
  v_used   int;
begin
  if v_code = '' then raise exception 'Enter a coupon code.'; end if;
  if p_lock then
    select * into c from public.coupons where upper(code) = v_code for update;
  else
    select * into c from public.coupons where upper(code) = v_code;
  end if;
  if not found then raise exception 'Coupon % does not exist.', v_code; end if;
  if not c.is_active then raise exception 'Coupon % is switched off.', c.code; end if;
  if c.valid_from is not null and v_today < c.valid_from then
    raise exception 'Coupon % can be used from %.', c.code, to_char(c.valid_from, 'DD Mon YYYY');
  end if;
  if c.valid_to is not null and v_today > c.valid_to then
    raise exception 'Coupon % expired on %.', c.code, to_char(c.valid_to, 'DD Mon YYYY');
  end if;

  select coalesce(sum(l.price * l.qty), 0),
         coalesce(sum(l.price * l.qty) filter (where l.eligible), 0),
         coalesce(sum(l.qty) filter (where l.eligible), 0)
    into v_sub, v_elig, v_units
  from public._coupon_lines(c, p_items) l;

  if v_sub < c.min_bill then
    raise exception 'Coupon % needs a bill of at least %.', c.code, v_cur || to_char(c.min_bill, 'FM999999990.00');
  end if;
  if v_units = 0 then
    raise exception 'Coupon % does not cover any item in this bill.', c.code;
  end if;

  if c.usage_limit is not null then
    select count(*) into v_used from public.orders
     where coupon_id = c.id and payment_status <> 'cancelled';
    if v_used >= c.usage_limit then raise exception 'Coupon % has been used up.', c.code; end if;
  end if;

  if c.per_customer_limit is not null then
    if p_phone is null then
      raise exception 'Coupon % needs the customer''s phone number. Go back and enter it.', c.code;
    end if;
    select count(*) into v_used from public.orders
     where coupon_id = c.id and phone = p_phone and payment_status <> 'cancelled';
    if v_used >= c.per_customer_limit then
      if c.per_customer_limit = 1 then
        raise exception 'This customer has already used coupon %.', c.code;
      end if;
      raise exception 'This customer has already used coupon % % times.', c.code, c.per_customer_limit;
    end if;
  end if;

  if c.kind = 'percent' then
    v_disc := round(v_elig * c.value / 100, 2);
  elsif c.kind = 'flat' then
    v_disc := least(c.value, v_elig);
  else
    v_free := (v_units / (c.buy_qty + c.get_qty)) * c.get_qty;
    if v_free = 0 then
      raise exception 'Coupon % needs % eligible items in the bill (buy %, get % free).',
        c.code, c.buy_qty + c.get_qty, c.buy_qty, c.get_qty;
    end if;
    select coalesce(sum(u.price), 0) into v_disc
    from (select l.price
            from public._coupon_lines(c, p_items) l
            cross join generate_series(1, l.qty)
           where l.eligible
           order by l.price
           limit v_free) u;
  end if;

  if c.max_discount is not null then v_disc := least(v_disc, c.max_discount); end if;
  v_disc := least(v_disc, v_sub);

  return jsonb_build_object(
    'coupon_id', c.id, 'code', c.code, 'description', c.description, 'kind', c.kind,
    'subtotal', v_sub, 'discount', v_disc, 'total', v_sub - v_disc);
end $$;

-- Full order as JSON (used by receipts). Now with subtotal, discount, coupon.
create or replace function public._order_json(p_id bigint)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'id', o.id, 'phone', o.phone, 'customer_name', o.customer_name, 'total', o.total,
    'subtotal', coalesce(o.subtotal, o.total), 'discount', o.discount, 'coupon_code', o.coupon_code,
    'payment_status', o.payment_status, 'payment_method', o.payment_method,
    'paid_at', o.paid_at, 'created_at', o.created_at, 'created_by', ad.username,
    'items', coalesce((select json_agg(json_build_object('name', oi.item_name, 'price', oi.price, 'qty', oi.qty) order by oi.id)
                         from public.order_items oi where oi.order_id = o.id), '[]'::json))
  from public.orders o
  left join public.admins ad on ad.id = o.created_by
  where o.id = p_id;
$$;

-- Any admin: preview a coupon on the bill being made.
create or replace function public.check_coupon(p_token uuid, p_code text, p_phone text, p_items jsonb)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_phone text := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
begin
  perform public._require_admin(p_token);
  if v_phone is not null and v_phone !~ '^[0-9]{10}$' then
    raise exception 'Enter a valid 10-digit phone number, or leave it blank.';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one item.';
  end if;
  return public._coupon_quote(p_code, p_items, v_phone, false)::json;
end $$;

drop function if exists public.create_order(uuid, text, text, jsonb, text);

create or replace function public.create_order(
  p_token uuid, p_phone text, p_customer_name text, p_items jsonb, p_payment_method text default 'cash',
  p_coupon_code text default null)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a        public.admins;
  v_phone  text := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
  v_name   text := nullif(trim(p_customer_name), '');
  v_method text := lower(trim(coalesce(p_payment_method, 'cash')));
  v_order  public.orders;
  v_count  int;
  v_warn   jsonb;
  v_quote  jsonb;
  v_sub    numeric;
  v_disc   numeric := 0;
begin
  a := public._require_admin(p_token);

  -- Optional, but a number that is given has to be a real one.
  if v_phone is not null and v_phone !~ '^[0-9]{10}$' then
    raise exception 'Enter a valid 10-digit phone number, or leave it blank.';
  end if;
  if v_method not in ('cash', 'upi', 'card') then
    raise exception 'Choose a valid payment method.';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one item.';
  end if;

  -- Checked again here (and the coupon row locked) so limits hold.
  if nullif(trim(p_coupon_code), '') is not null then
    v_quote := public._coupon_quote(p_coupon_code, p_items, v_phone, true);
  end if;

  if v_phone is not null then
    insert into public.customers(phone, name) values (v_phone, v_name)
    on conflict (phone) do update set name = coalesce(excluded.name, public.customers.name);
  end if;

  insert into public.orders(phone, customer_name, created_by, payment_method, payment_status, paid_at)
  values (v_phone,
          coalesce(v_name, (select name from public.customers where phone = v_phone)), a.id,
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

  select sum(price * qty) into v_sub from public.order_items where order_id = v_order.id;
  if v_quote is not null then v_disc := least((v_quote->>'discount')::numeric, v_sub); end if;

  update public.orders
     set subtotal    = v_sub,
         discount    = v_disc,
         total       = v_sub - v_disc,
         coupon_id   = (v_quote->>'coupon_id')::bigint,
         coupon_code = v_quote->>'code'
   where id = v_order.id;

  return (public._order_json(v_order.id)::jsonb || jsonb_build_object('stock_warnings', v_warn))::json;
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
                        or o.customer_name ilike '%' || q || '%' or o.id::text = q
                        or o.coupon_code ilike q),
    'rows', coalesce(json_agg(r order by r.created_at desc), '[]'::json))
  into v
  from (
    select o.id, o.phone, o.customer_name, o.total, o.subtotal, o.discount, o.coupon_code,
           o.payment_status, o.payment_method, o.paid_at, o.created_at,
           ad.username as created_by,
           (select json_agg(json_build_object('name', oi.item_name, 'price', oi.price, 'qty', oi.qty) order by oi.id)
              from public.order_items oi where oi.order_id = o.id) as items
    from public.orders o
    left join public.admins ad on ad.id = o.created_by
    where q is null or o.phone like '%' || q || '%'
       or o.customer_name ilike '%' || q || '%' or o.id::text = q
       or o.coupon_code ilike q
    order by o.created_at desc
    limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
  ) r;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Coupons (super admin)
-- ---------------------------------------------------------------------
create or replace function public.list_coupons(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token, true);
  select coalesce(json_agg(x order by x.is_active desc, x.created_at desc), '[]'::json) into v
  from (
    select c.*,
           coalesce(u.uses, 0) as uses,
           coalesce(u.given, 0) as discount_given
    from public.coupons c
    left join (select coupon_id, count(*) as uses, sum(discount) as given
                 from public.orders
                where coupon_id is not null and payment_status <> 'cancelled'
                group by coupon_id) u on u.coupon_id = c.id
  ) x;
  return v;
end $$;

-- p_coupon: {code, description, kind, value, max_discount, min_bill, buy_qty,
-- get_qty, applies_to, item_ids, categories, valid_from, valid_to,
-- usage_limit, per_customer_limit, is_active}. p_id null creates.
create or replace function public.upsert_coupon(p_token uuid, p_id bigint, p_coupon jsonb)
returns public.coupons
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a       public.admins;
  j       jsonb := coalesce(p_coupon, '{}'::jsonb);
  c       public.coupons;
  v_old   public.coupons;
  v_diff  jsonb;
  v_code  text := upper(trim(coalesce(j->>'code', '')));
  v_kind  text := lower(trim(coalesce(j->>'kind', '')));
  v_value numeric := coalesce(nullif(j->>'value', '')::numeric, 0);
  v_max   numeric := nullif(j->>'max_discount', '')::numeric;
  v_min   numeric := coalesce(nullif(j->>'min_bill', '')::numeric, 0);
  v_buy   int := nullif(j->>'buy_qty', '')::int;
  v_get   int := nullif(j->>'get_qty', '')::int;
  v_scope text := coalesce(nullif(lower(trim(j->>'applies_to')), ''), 'all');
  v_items bigint[] := coalesce((select array_agg(distinct x::bigint) from jsonb_array_elements_text(coalesce(j->'item_ids', '[]'::jsonb)) x), '{}');
  v_cats  text[] := coalesce((select array_agg(distinct trim(x)) from jsonb_array_elements_text(coalesce(j->'categories', '[]'::jsonb)) x where trim(x) <> ''), '{}');
  v_from  date := nullif(j->>'valid_from', '')::date;
  v_to    date := nullif(j->>'valid_to', '')::date;
  v_uses  int := nullif(j->>'usage_limit', '')::int;
  v_per   int := nullif(j->>'per_customer_limit', '')::int;
begin
  a := public._require_admin(p_token, true);

  if v_code !~ '^[A-Z0-9_-]{3,20}$' then
    raise exception 'Code must be 3 to 20 letters, numbers, - or _.';
  end if;
  if v_kind not in ('percent', 'flat', 'bogo') then raise exception 'Choose a coupon type.'; end if;
  if v_kind = 'percent' and (v_value <= 0 or v_value > 100) then
    raise exception 'Percentage must be more than 0 and at most 100.';
  end if;
  if v_kind = 'flat' and v_value <= 0 then raise exception 'Discount amount must be more than 0.'; end if;
  if v_kind = 'bogo' then
    if coalesce(v_buy, 0) < 1 or coalesce(v_get, 0) < 1 then
      raise exception 'Buy and free quantities must both be at least 1.';
    end if;
    v_value := 0;
  else
    v_buy := null;
    v_get := null;
  end if;
  if v_kind = 'flat' then v_max := null; end if;
  if v_max is not null and v_max <= 0 then raise exception 'Maximum discount must be more than 0.'; end if;
  if v_min < 0 then raise exception 'Minimum bill cannot be negative.'; end if;
  if v_scope not in ('all', 'items') then raise exception 'Choose what the coupon applies to.'; end if;
  if v_scope = 'all' then
    v_items := '{}';
    v_cats := '{}';
  elsif cardinality(v_items) = 0 and cardinality(v_cats) = 0 then
    raise exception 'Pick at least one item or category for this coupon.';
  end if;
  if v_from is not null and v_to is not null and v_to < v_from then
    raise exception 'Valid until must be on or after valid from.';
  end if;
  if v_uses is not null and v_uses < 1 then raise exception 'Total uses must be at least 1, or blank.'; end if;
  if v_per is not null and v_per < 1 then raise exception 'Uses per customer must be at least 1, or blank.'; end if;
  if exists (select 1 from public.coupons where upper(code) = v_code and id is distinct from p_id) then
    raise exception 'Coupon code % already exists.', v_code;
  end if;

  if p_id is null then
    insert into public.coupons(code, description, kind, value, max_discount, min_bill, buy_qty, get_qty,
                               applies_to, item_ids, categories, valid_from, valid_to,
                               usage_limit, per_customer_limit, is_active, created_by)
    values (v_code, nullif(trim(j->>'description'), ''), v_kind, v_value, v_max, v_min, v_buy, v_get,
            v_scope, v_items, v_cats, v_from, v_to,
            v_uses, v_per, coalesce((j->>'is_active')::boolean, true), a.id)
    returning * into c;
    perform public._audit(a, 'coupon.create', c.id::text,
      to_jsonb(c) - 'id' - 'created_at' - 'updated_at' - 'created_by' || jsonb_build_object('name', c.code));
  else
    select * into v_old from public.coupons where id = p_id for update;
    if not found then raise exception 'Coupon not found.'; end if;
    update public.coupons
       set code = v_code, description = nullif(trim(j->>'description'), ''), kind = v_kind,
           value = v_value, max_discount = v_max, min_bill = v_min, buy_qty = v_buy, get_qty = v_get,
           applies_to = v_scope, item_ids = v_items, categories = v_cats,
           valid_from = v_from, valid_to = v_to, usage_limit = v_uses, per_customer_limit = v_per,
           is_active = coalesce((j->>'is_active')::boolean, true), updated_at = now()
     where id = p_id
    returning * into c;
    v_diff := public._jsonb_diff(to_jsonb(v_old) - 'created_at' - 'updated_at',
                                 to_jsonb(c) - 'created_at' - 'updated_at');
    if v_diff <> '{}'::jsonb then
      perform public._audit(a, 'coupon.update', c.id::text, jsonb_build_object('name', c.code, 'changes', v_diff));
    end if;
  end if;
  return c;
end $$;

-- Past bills keep the code they were given (orders.coupon_code).
create or replace function public.delete_coupon(p_token uuid, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; c public.coupons;
begin
  a := public._require_admin(p_token, true);
  select * into c from public.coupons where id = p_id;
  if not found then raise exception 'Coupon not found.'; end if;
  perform public._audit(a, 'coupon.delete', p_id::text,
    to_jsonb(c) - 'id' - 'created_at' - 'updated_at' - 'created_by' || jsonb_build_object('name', c.code));
  delete from public.coupons where id = p_id;
end $$;

revoke all on function
  public._coupon_lines(public.coupons, jsonb), public._coupon_quote(text, jsonb, text, boolean)
from public, anon, authenticated;

revoke all on function
  public.create_order(uuid, text, text, jsonb, text, text), public.check_coupon(uuid, text, text, jsonb),
  public.list_coupons(uuid), public.upsert_coupon(uuid, bigint, jsonb), public.delete_coupon(uuid, bigint)
from public;

grant execute on function
  public.create_order(uuid, text, text, jsonb, text, text), public.check_coupon(uuid, text, text, jsonb),
  public.list_coupons(uuid), public.upsert_coupon(uuid, bigint, jsonb), public.delete_coupon(uuid, bigint)
to anon, authenticated;

notify pgrst, 'reload schema';
