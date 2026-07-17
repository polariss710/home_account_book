begin;

create table if not exists public.home_school_fx_syncs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  cny_transaction_id uuid not null unique references public.home_cny_transactions(id) on delete restrict,
  jpy_transaction_id uuid not null unique references public.home_jpy_transactions(id) on delete restrict,
  school_inbound_event_id uuid not null unique,
  school_account_transaction_id uuid not null unique,
  synced_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists home_school_fx_syncs_user_synced_at_idx
  on public.home_school_fx_syncs(user_id, synced_at desc);

alter table public.home_school_fx_syncs enable row level security;
drop policy if exists home_school_fx_syncs_user_select on public.home_school_fx_syncs;
create policy home_school_fx_syncs_user_select
  on public.home_school_fx_syncs for select to authenticated
  using (user_id = auth.uid());

create or replace function public.home_mark_cny_to_jpy_fx_school_synced(
  p_cny_transaction_id uuid,
  p_school_inbound_event_id uuid,
  p_school_account_transaction_id uuid
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_cny public.home_cny_transactions%rowtype;
  v_jpy public.home_jpy_transactions%rowtype;
  v_existing public.home_school_fx_syncs%rowtype;
  v_sync_id uuid;
begin
  if v_user_id is null then
    return jsonb_build_object('ok', false, 'message', 'Cash 登录用户不存在。');
  end if;
  if p_cny_transaction_id is null or p_school_inbound_event_id is null
    or p_school_account_transaction_id is null then
    return jsonb_build_object('ok', false, 'message', 'School 同步身份不完整。');
  end if;

  select * into v_cny from public.home_cny_transactions
  where id = p_cny_transaction_id and user_id = v_user_id
    and currency = 'CNY' and transaction_type = 'fx_out';
  if not found or v_cny.linked_jpy_transaction_id is null then
    return jsonb_build_object('ok', false, 'message', '没有找到完整的人民币购汇流水。');
  end if;

  select * into v_jpy from public.home_jpy_transactions
  where id = v_cny.linked_jpy_transaction_id and user_id = v_user_id
    and currency = 'JPY' and transaction_type = 'fx_in'
    and linked_cny_transaction_id = v_cny.id;
  if not found then
    return jsonb_build_object('ok', false, 'message', '没有找到双向关联的日元入金流水。');
  end if;

  select * into v_existing from public.home_school_fx_syncs
  where cny_transaction_id = v_cny.id;
  if found then
    if v_existing.user_id = v_user_id and v_existing.jpy_transaction_id = v_jpy.id
      and v_existing.school_inbound_event_id = p_school_inbound_event_id
      and v_existing.school_account_transaction_id = p_school_account_transaction_id then
      return jsonb_build_object('ok', true, 'inserted', false, 'sync_id', v_existing.id,
        'message', 'Cash 购汇已存在相同 School 同步标记。');
    end if;
    return jsonb_build_object('ok', false,
      'message', 'Cash 购汇已绑定其他 School 入站身份，禁止覆盖。');
  end if;

  insert into public.home_school_fx_syncs (
    user_id, cny_transaction_id, jpy_transaction_id,
    school_inbound_event_id, school_account_transaction_id
  ) values (
    v_user_id, v_cny.id, v_jpy.id,
    p_school_inbound_event_id, p_school_account_transaction_id
  ) returning id into v_sync_id;

  return jsonb_build_object('ok', true, 'inserted', true, 'sync_id', v_sync_id,
    'message', 'Cash 购汇已标记为 School 同步并进入只读保护。');
exception when unique_violation then
  return jsonb_build_object('ok', false,
    'message', 'Cash 或 School 同步身份已被其他购汇记录使用。');
end;
$$;

create or replace function public.home_guard_school_synced_fx_mutation()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_table_name = 'home_cny_transactions' and exists (
    select 1 from public.home_school_fx_syncs where cny_transaction_id = old.id
  ) then
    raise exception '已回写 School 的人民币购汇流水不可编辑或删除。';
  end if;
  if tg_table_name = 'home_jpy_transactions' and exists (
    select 1 from public.home_school_fx_syncs where jpy_transaction_id = old.id
  ) then
    raise exception '已回写 School 的日元入金流水不可编辑或删除。';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

drop trigger if exists home_cny_transactions_school_fx_guard on public.home_cny_transactions;
create trigger home_cny_transactions_school_fx_guard before update or delete
  on public.home_cny_transactions for each row
  execute function public.home_guard_school_synced_fx_mutation();
drop trigger if exists home_jpy_transactions_school_fx_guard on public.home_jpy_transactions;
create trigger home_jpy_transactions_school_fx_guard before update or delete
  on public.home_jpy_transactions for each row
  execute function public.home_guard_school_synced_fx_mutation();

revoke all on table public.home_school_fx_syncs from public, anon, authenticated;
grant select on table public.home_school_fx_syncs to authenticated;
grant all on table public.home_school_fx_syncs to service_role;
revoke all on function public.home_mark_cny_to_jpy_fx_school_synced(uuid, uuid, uuid) from public, anon;
grant execute on function public.home_mark_cny_to_jpy_fx_school_synced(uuid, uuid, uuid) to authenticated, service_role;
revoke all on function public.home_guard_school_synced_fx_mutation() from public, anon, authenticated;
grant execute on function public.home_guard_school_synced_fx_mutation() to service_role;

commit;
