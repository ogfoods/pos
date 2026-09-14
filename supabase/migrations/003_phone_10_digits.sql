-- Migration 003: require exactly 10-digit phone numbers when creating orders.
-- Run once in Supabase Dashboard -> SQL Editor on databases created before this change.
-- (schema.sql already includes this for fresh installs.) Same signature, so grants are kept.

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

  if v_phone !~ '^[0-9]{10}$' then
    raise exception 'Enter a valid 10-digit phone number.';
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
