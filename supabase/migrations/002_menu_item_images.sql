-- Migration 002: optional image per menu item (shown in the New bill modal).
-- Run once in Supabase Dashboard -> SQL Editor on databases created before this change.
-- (schema.sql already includes these changes for fresh installs.)

alter table public.menu_items add column if not exists image_url text;

drop function if exists public.upsert_menu_item(uuid, bigint, text, text, numeric, boolean);

create or replace function public.upsert_menu_item(
  p_token uuid, p_id bigint, p_name text, p_category text, p_price numeric, p_is_active boolean,
  p_image_url text default null)
returns public.menu_items
language plpgsql security definer set search_path = public, extensions
as $$
declare
  m     public.menu_items;
  v_img text := nullif(trim(p_image_url), '');
begin
  perform public._require_admin(p_token, true);
  if coalesce(trim(p_name), '') = '' then raise exception 'Name is required.'; end if;
  if v_img is not null and v_img !~* '^https?://' then
    raise exception 'Image URL must start with http:// or https://';
  end if;

  if p_id is null then
    insert into public.menu_items(name, category, price, is_active, image_url)
    values (trim(p_name), coalesce(nullif(trim(p_category), ''), 'General'), p_price, coalesce(p_is_active, true), v_img)
    returning * into m;
  else
    update public.menu_items
       set name = trim(p_name),
           category = coalesce(nullif(trim(p_category), ''), 'General'),
           price = p_price,
           is_active = coalesce(p_is_active, true),
           image_url = v_img
     where id = p_id
    returning * into m;
    if m.id is null then raise exception 'Menu item not found.'; end if;
  end if;
  return m;
end $$;

revoke all on function public.upsert_menu_item(uuid, bigint, text, text, numeric, boolean, text) from public;
grant execute on function public.upsert_menu_item(uuid, bigint, text, text, numeric, boolean, text) to anon, authenticated;

-- Refresh the API schema cache so the new column and function signature are visible immediately.
notify pgrst, 'reload schema';
