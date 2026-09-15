-- Migration 005: ingredient usage report (days in IST, Asia/Kolkata).
-- Run once in Supabase Dashboard -> SQL Editor. (schema.sql already includes this.)

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

notify pgrst, 'reload schema';
