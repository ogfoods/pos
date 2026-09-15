-- Migration 011: public home page (shop details, opening hours, live kitchen board, public menu).
-- Run once in Supabase Dashboard -> SQL Editor, after 010. (schema.sql already includes this.)

-- ---------------------------------------------------------------------
-- Settings: home page details
-- opening_hours: {"mon": {"closed": false, "open": "07:00", "close": "22:00"}, ..., "sun": {"closed": true}}
-- Times are IST. close earlier than open means the shop closes after midnight.
-- ---------------------------------------------------------------------
alter table public.settings add column if not exists tagline text;
alter table public.settings add column if not exists whatsapp text;
alter table public.settings add column if not exists maps_url text;
alter table public.settings add column if not exists cover_image_url text;
alter table public.settings add column if not exists opening_hours jsonb;

-- ---------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------
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
-- Permissions
-- ---------------------------------------------------------------------
revoke all on function public._normalize_hours(jsonb) from public, anon, authenticated;

revoke all on function public.public_kitchen(), public.public_menu() from public;
grant execute on function public.public_kitchen(), public.public_menu() to anon, authenticated;

notify pgrst, 'reload schema';
