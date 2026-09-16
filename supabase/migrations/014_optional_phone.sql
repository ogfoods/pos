-- Migration 014: a bill no longer needs a phone number.
--
-- Walk-in customers who do not want to give a number can still be billed.
-- When a number is given it is still validated and still creates/updates the
-- customer row, so order history by phone keeps working. Without one, the
-- order simply has no phone, and the WhatsApp receipt is not offered.
--
-- Run once in Supabase Dashboard -> SQL Editor. (schema.sql already includes this.)

alter table public.orders alter column phone drop not null;

create or replace function public.create_order(
  p_token uuid, p_phone text, p_customer_name text, p_items jsonb, p_payment_method text default 'cash')
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

  update public.orders
     set total = (select sum(price * qty) from public.order_items where order_id = v_order.id)
   where id = v_order.id;

  return (public._order_json(v_order.id)::jsonb || jsonb_build_object('stock_warnings', v_warn))::json;
end $$;

notify pgrst, 'reload schema';
