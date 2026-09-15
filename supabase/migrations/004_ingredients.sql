-- Migration 004: ingredients, menu item recipes, and per-order ingredient snapshots.
-- Run once in Supabase Dashboard -> SQL Editor on databases created before this change.
-- (schema.sql already includes these changes for fresh installs.)

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists public.ingredients (
  id         bigint generated always as identity primary key,
  name       text not null,
  unit       text not null default 'g' check (unit in ('g', 'kg', 'ml', 'l', 'pcs')),
  created_at timestamptz not null default now()
);
create unique index if not exists ingredients_name_uidx on public.ingredients (lower(name));

create table if not exists public.menu_item_ingredients (
  menu_item_id  bigint not null references public.menu_items(id) on delete cascade,
  ingredient_id bigint not null references public.ingredients(id) on delete cascade,
  qty           numeric(12,3) not null check (qty > 0),
  primary key (menu_item_id, ingredient_id)
);
create index if not exists menu_item_ingredients_ing_idx on public.menu_item_ingredients(ingredient_id);

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

-- ---------------------------------------------------------------------
-- Ingredient + recipe functions (super admin)
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
    select i.id, i.name, i.unit,
           (select count(*) from public.menu_item_ingredients mi where mi.ingredient_id = i.id) as used_count
    from public.ingredients i
  ) r;
  return v;
end $$;

create or replace function public.upsert_ingredient(p_token uuid, p_id bigint, p_name text, p_unit text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v_id bigint; v_name text := trim(p_name);
begin
  perform public._require_admin(p_token, true);
  if coalesce(v_name, '') = '' then raise exception 'Name is required.'; end if;
  if p_unit is null or p_unit not in ('g', 'kg', 'ml', 'l', 'pcs') then
    raise exception 'Choose a valid unit.';
  end if;

  begin
    if p_id is null then
      insert into public.ingredients(name, unit) values (v_name, p_unit) returning id into v_id;
    else
      update public.ingredients set name = v_name, unit = p_unit where id = p_id returning id into v_id;
      if v_id is null then raise exception 'Ingredient not found.'; end if;
    end if;
  exception when unique_violation then
    raise exception 'An ingredient named "%" already exists.', v_name;
  end;

  return json_build_object('id', v_id);
end $$;

create or replace function public.delete_ingredient(p_token uuid, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
begin
  perform public._require_admin(p_token, true);
  delete from public.ingredients where id = p_id;
end $$;

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

create or replace function public.set_menu_item_ingredients(p_token uuid, p_menu_item_id bigint, p_items jsonb)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare v_items jsonb := coalesce(p_items, '[]'::jsonb);
begin
  perform public._require_admin(p_token, true);
  if not exists (select 1 from public.menu_items where id = p_menu_item_id) then
    raise exception 'Menu item not found.';
  end if;
  if jsonb_typeof(v_items) <> 'array' then raise exception 'Invalid ingredients list.'; end if;
  if exists (
    select 1 from jsonb_array_elements(v_items) e
    where nullif(e->>'ingredient_id', '') is null
       or coalesce(nullif(e->>'qty', '')::numeric, 0) <= 0
  ) then
    raise exception 'Each ingredient needs a quantity greater than 0.';
  end if;

  delete from public.menu_item_ingredients where menu_item_id = p_menu_item_id;

  insert into public.menu_item_ingredients(menu_item_id, ingredient_id, qty)
  select p_menu_item_id, i.id, sum((e->>'qty')::numeric)
  from jsonb_array_elements(v_items) e
  join public.ingredients i on i.id = (e->>'ingredient_id')::bigint
  group by i.id;
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
-- create_order: also snapshot ingredients consumed (same signature, grants kept)
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

  insert into public.order_item_ingredients(order_id, order_item_id, ingredient_id, ingredient_name, unit, qty)
  select oi.order_id, oi.id, ing.id, ing.name, ing.unit, r.qty * oi.qty
  from public.order_items oi
  join public.menu_item_ingredients r on r.menu_item_id = oi.menu_item_id
  join public.ingredients ing on ing.id = r.ingredient_id
  where oi.order_id = v_order.id;

  update public.orders
     set total = (select sum(price * qty) from public.order_items where order_id = v_order.id)
   where id = v_order.id
  returning * into v_order;

  return json_build_object('id', v_order.id, 'total', v_order.total, 'created_at', v_order.created_at);
end $$;

notify pgrst, 'reload schema';
