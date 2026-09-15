-- Migration 010: ingredient stock tracking and out-of-stock handling.
-- Run once in Supabase Dashboard -> SQL Editor, after 009. (schema.sql already includes this.)

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
-- Stock is tracked only for ingredients with track_stock = true (turned on
-- automatically the first time stock is recorded), so existing menus keep
-- selling after this migration.
alter table public.ingredients add column if not exists track_stock boolean not null default false;
alter table public.ingredients add column if not exists stock numeric(14,3) not null default 0;
alter table public.ingredients add column if not exists low_stock_at numeric(14,3);

-- Shop setting: true = hide/block items whose tracked ingredients ran out;
-- false = keep selling with a warning (stock may go below zero).
alter table public.settings add column if not exists hide_out_of_stock boolean not null default true;

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

-- ---------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Settings: add hide_out_of_stock
-- ---------------------------------------------------------------------
create or replace function public.get_settings()
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'shop_name', shop_name, 'shop_address', shop_address, 'shop_phone', shop_phone,
    'currency', currency, 'upi_id', upi_id, 'country_code', country_code,
    'receipt_footer', receipt_footer, 'hide_out_of_stock', hide_out_of_stock, 'updated_at', updated_at)
  from public.settings where id = 1;
$$;

-- Super admin. p_settings: {shop_name, shop_address, shop_phone, currency, upi_id, country_code,
-- receipt_footer, hide_out_of_stock}. hide_out_of_stock keeps its value when the key is missing.
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
  v_hide   boolean;
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
  v_hide := case when jsonb_typeof(s->'hide_out_of_stock') = 'boolean' then (s->'hide_out_of_stock')::boolean
                 else v_old.hide_out_of_stock end;

  update public.settings
     set shop_name = v_name, shop_address = v_addr, shop_phone = v_phone, currency = v_curr,
         upi_id = v_upi, country_code = v_cc, receipt_footer = v_footer, hide_out_of_stock = v_hide,
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
-- Orders: deduct stock on billing, restore on cancel / delete
-- ---------------------------------------------------------------------
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
-- Ingredients: include stock fields
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
-- Permissions
-- ---------------------------------------------------------------------
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

notify pgrst, 'reload schema';
