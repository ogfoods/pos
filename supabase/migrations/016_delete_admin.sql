-- Migration 016: super admin can delete a user.
--
-- Sign-out only ends sessions; this removes the account. Safe because every
-- table referencing admins does so with on delete set null (orders.created_by,
-- shifts.admin_id/closed_by, audit_log.admin_id, coupons.created_by,
-- settings.updated_by, admin_sessions.approved_by) or cascade
-- (admin_sessions.admin_id). Past bills, shifts and audit rows are kept; their
-- author simply shows blank.
--
-- A super admin cannot delete their own account (same rule as demoting or
-- deactivating yourself in upsert_admin).
--
-- Run once in Supabase Dashboard -> SQL Editor. (schema.sql already includes this.)

create or replace function public.delete_admin(p_token uuid, p_id bigint)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare a public.admins; v_user public.admins;
begin
  a := public._require_admin(p_token, true);
  if p_id = a.id then
    raise exception 'You cannot delete your own account.';
  end if;
  select * into v_user from public.admins where id = p_id;
  if not found then raise exception 'User not found.'; end if;

  perform public._audit(a, 'staff.delete', p_id::text,
    jsonb_build_object('username', v_user.username, 'role', v_user.role));
  delete from public.admins where id = p_id;
end $$;

revoke all on function public.delete_admin(uuid, bigint) from public;
grant execute on function public.delete_admin(uuid, bigint) to anon, authenticated;

notify pgrst, 'reload schema';
