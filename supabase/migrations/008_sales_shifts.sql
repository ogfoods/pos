-- Migration 008: sales report and cash shifts (open / close with cash count).
-- Run once in Supabase Dashboard -> SQL Editor, after 007. (schema.sql already includes this.)

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
-- One cash shift per admin at a time. Totals are frozen into `totals` at close.
create table if not exists public.shifts (
  id            bigint generated always as identity primary key,
  admin_id      bigint references public.admins(id) on delete set null,
  opened_at     timestamptz not null default now(),
  opening_cash  numeric(10,2) not null check (opening_cash >= 0),
  closed_at     timestamptz,
  closed_by     bigint references public.admins(id) on delete set null,
  counted_cash  numeric(10,2),
  expected_cash numeric(10,2),
  difference    numeric(10,2),
  totals        jsonb,
  note          text
);
create unique index if not exists shifts_one_open_idx on public.shifts(admin_id) where closed_at is null;
create index if not exists shifts_opened_idx on public.shifts(opened_at desc);
create index if not exists orders_created_by_idx on public.orders(created_by, created_at);
alter table public.shifts enable row level security;

-- ---------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------
-- Sales by one admin between two times (orders they billed).
create or replace function public._shift_totals(p_admin_id bigint, p_from timestamptz, p_to timestamptz)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'orders',          count(*) filter (where payment_status = 'paid'),
    'sales',           coalesce(sum(total) filter (where payment_status = 'paid'), 0),
    'cash',            coalesce(sum(total) filter (where payment_status = 'paid' and payment_method = 'cash'), 0),
    'upi',             coalesce(sum(total) filter (where payment_status = 'paid' and payment_method = 'upi'), 0),
    'card',            coalesce(sum(total) filter (where payment_status = 'paid' and payment_method = 'card'), 0),
    'pending_count',   count(*) filter (where payment_status = 'pending'),
    'pending_total',   coalesce(sum(total) filter (where payment_status = 'pending'), 0),
    'cancelled_count', count(*) filter (where payment_status = 'cancelled'),
    'cancelled_total', coalesce(sum(total) filter (where payment_status = 'cancelled'), 0))
  from public.orders
  where created_by = p_admin_id and created_at >= p_from and created_at < p_to;
$$;

-- Shift as JSON. Open shifts get live totals and expected cash up to now.
create or replace function public._shift_json(p_id bigint)
returns json
language sql stable security definer set search_path = public
as $$
  select json_build_object(
    'id', s.id, 'admin_id', s.admin_id, 'username', ad.username,
    'opened_at', s.opened_at, 'closed_at', s.closed_at, 'closed_by', cb.username,
    'is_open', s.closed_at is null,
    'opening_cash', s.opening_cash,
    'totals', t.totals,
    'expected_cash', coalesce(s.expected_cash, s.opening_cash + (t.totals->>'cash')::numeric),
    'counted_cash', s.counted_cash, 'difference', s.difference, 'note', s.note)
  from public.shifts s
  left join public.admins ad on ad.id = s.admin_id
  left join public.admins cb on cb.id = s.closed_by
  cross join lateral (select coalesce(s.totals, public._shift_totals(s.admin_id, s.opened_at, now())) as totals) t
  where s.id = p_id;
$$;

-- ---------------------------------------------------------------------
-- Shifts
-- ---------------------------------------------------------------------
-- Any admin: own open shift (with live totals) or null.
create or replace function public.current_shift(p_token uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v_id bigint;
begin
  a := public._require_admin(p_token);
  select id into v_id from public.shifts where admin_id = a.id and closed_at is null;
  if v_id is null then return null; end if;
  return public._shift_json(v_id);
end $$;

create or replace function public.open_shift(p_token uuid, p_opening_cash numeric)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v_id bigint;
begin
  a := public._require_admin(p_token);
  if p_opening_cash is null or p_opening_cash < 0 or p_opening_cash > 10000000 then
    raise exception 'Enter the opening cash in the drawer (0 or more).';
  end if;
  begin
    insert into public.shifts(admin_id, opening_cash) values (a.id, round(p_opening_cash, 2)) returning id into v_id;
  exception when unique_violation then
    raise exception 'You already have an open shift.';
  end;
  perform public._audit(a, 'shift.open', v_id::text,
    jsonb_build_object('username', a.username, 'opening_cash', round(p_opening_cash, 2)));
  return public._shift_json(v_id);
end $$;

-- Closes your open shift, or (super admin) any open shift by id.
create or replace function public.close_shift(
  p_token uuid, p_counted_cash numeric, p_note text default null, p_shift_id bigint default null)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare
  a        public.admins;
  s        public.shifts;
  v_totals jsonb;
  v_expect numeric(10,2);
  v_note   text := nullif(trim(p_note), '');
begin
  a := public._require_admin(p_token);
  if p_shift_id is null then
    select * into s from public.shifts where admin_id = a.id and closed_at is null for update;
    if not found then raise exception 'You have no open shift.'; end if;
  else
    select * into s from public.shifts where id = p_shift_id for update;
    if not found then raise exception 'Shift not found.'; end if;
    if s.admin_id is distinct from a.id and a.role <> 'super' then
      raise exception 'Super admin access required.' using errcode = '42501';
    end if;
    if s.closed_at is not null then raise exception 'This shift is already closed.'; end if;
  end if;
  if p_counted_cash is null or p_counted_cash < 0 or p_counted_cash > 10000000 then
    raise exception 'Enter the cash counted in the drawer (0 or more).';
  end if;
  if length(coalesce(v_note, '')) > 200 then raise exception 'Note can be at most 200 characters.'; end if;

  v_totals := public._shift_totals(s.admin_id, s.opened_at, now());
  v_expect := s.opening_cash + (v_totals->>'cash')::numeric;

  update public.shifts
     set closed_at = now(), closed_by = a.id, counted_cash = round(p_counted_cash, 2),
         expected_cash = v_expect, difference = round(p_counted_cash, 2) - v_expect,
         totals = v_totals, note = v_note
   where id = s.id;

  perform public._audit(a, 'shift.close', s.id::text,
    jsonb_build_object(
      'username', (select username from public.admins where id = s.admin_id),
      'opening_cash', s.opening_cash, 'expected_cash', v_expect,
      'counted_cash', round(p_counted_cash, 2), 'difference', round(p_counted_cash, 2) - v_expect));
  return public._shift_json(s.id);
end $$;

-- Super admin: shifts opened between IST dates, newest first (max 200).
create or replace function public.list_shifts(p_token uuid, p_from date, p_to date)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v json;
begin
  perform public._require_admin(p_token, true);
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  select coalesce(json_agg(public._shift_json(x.id) order by x.opened_at desc), '[]'::json) into v
  from (select id, opened_at from public.shifts
        where opened_at >= (p_from::timestamp at time zone 'Asia/Kolkata')
          and opened_at <  ((p_to + 1)::timestamp at time zone 'Asia/Kolkata')
        order by opened_at desc limit 200) x;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Sales report (super admin). Days and hours are IST; dated by bill time.
-- Sales, orders and average count paid bills only.
-- ---------------------------------------------------------------------
create or replace function public.sales_report(p_token uuid, p_from date, p_to date)
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
    select ord.id, ord.total, ord.payment_status, ord.payment_method, ord.created_by,
           (ord.created_at at time zone 'Asia/Kolkata') as local_at
    from public.orders ord
    where ord.created_at >= (v_from::timestamp at time zone 'Asia/Kolkata')
      and ord.created_at <  ((v_to + 1)::timestamp at time zone 'Asia/Kolkata')
  ), p as (
    select * from o where payment_status = 'paid'
  )
  select json_build_object(
    'from', v_from,
    'to', v_to,
    'summary', (select json_build_object('orders', count(*), 'sales', coalesce(sum(total), 0),
                                         'avg', coalesce(round(avg(total), 2), 0)) from p),
    'pending', (select json_build_object('orders', count(*), 'total', coalesce(sum(total), 0))
                from o where payment_status = 'pending'),
    'cancelled', (select json_build_object('orders', count(*), 'total', coalesce(sum(total), 0))
                  from o where payment_status = 'cancelled'),
    'by_method', (select coalesce(json_agg(json_build_object('method', x.m, 'orders', x.n, 'total', x.s) order by x.s desc), '[]'::json)
                  from (select coalesce(payment_method, 'unknown') m, count(*) n, sum(total) s from p group by 1) x),
    'by_day', (select json_agg(json_build_object('day', d::date, 'orders', coalesce(x.n, 0), 'total', coalesce(x.s, 0)) order by d)
               from generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') d
               left join (select local_at::date dd, count(*) n, sum(total) s from p group by 1) x on x.dd = d::date),
    'by_hour', (select json_agg(json_build_object('hour', h, 'orders', coalesce(x.n, 0), 'total', coalesce(x.s, 0)) order by h)
                from generate_series(0, 23) h
                left join (select extract(hour from local_at)::int hr, count(*) n, sum(total) s from p group by 1) x on x.hr = h),
    'top_items', (select coalesce(json_agg(t order by t.revenue desc, t.qty desc), '[]'::json)
                  from (select oi.item_name as name, sum(oi.qty)::int as qty, sum(oi.qty * oi.price) as revenue
                        from public.order_items oi join p on p.id = oi.order_id
                        group by oi.item_name order by 3 desc, 2 desc limit 10) t),
    'by_staff', (select coalesce(json_agg(json_build_object('username', coalesce(ad.username, '—'), 'orders', x.n, 'total', x.s) order by x.s desc), '[]'::json)
                 from (select created_by, count(*) n, sum(total) s from p group by 1) x
                 left join public.admins ad on ad.id = x.created_by)
  ) into v;

  return v;
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
revoke all on function
  public._shift_totals(bigint, timestamptz, timestamptz), public._shift_json(bigint)
from public, anon, authenticated;

revoke all on function
  public.current_shift(uuid), public.open_shift(uuid, numeric),
  public.close_shift(uuid, numeric, text, bigint), public.list_shifts(uuid, date, date),
  public.sales_report(uuid, date, date)
from public;

grant execute on function
  public.current_shift(uuid), public.open_shift(uuid, numeric),
  public.close_shift(uuid, numeric, text, bigint), public.list_shifts(uuid, date, date),
  public.sales_report(uuid, date, date)
to anon, authenticated;

notify pgrst, 'reload schema';
