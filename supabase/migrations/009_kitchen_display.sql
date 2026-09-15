-- Migration 009: kitchen display (prep status per order + live refresh ping).
-- Run once in Supabase Dashboard -> SQL Editor, after 008. (schema.sql already includes this.)

-- ---------------------------------------------------------------------
-- Orders: kitchen status. Orders that exist when this column is first
-- added are marked served, so the kitchen does not fill with old bills.
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
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
-- Permissions
-- ---------------------------------------------------------------------
revoke all on function public._kitchen_ping() from public, anon, authenticated;

revoke all on function public.kitchen_orders(uuid), public.set_kitchen_status(uuid, bigint, text) from public;
grant execute on function public.kitchen_orders(uuid), public.set_kitchen_status(uuid, bigint, text) to anon, authenticated;

notify pgrst, 'reload schema';
