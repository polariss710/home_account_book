#!/bin/zsh
set -euo pipefail

[[ -n "${CASH_SUPABASE_DB_URL:-}" ]] || { print -u2 'CASH_SUPABASE_DB_URL is required'; exit 2; }

TASK_TMPDIR=$(mktemp -d /private/tmp/phaseb-delete-concurrency.XXXXXX)
PGDATA_DIR="$TASK_TMPDIR/pgdata"
PGSOCKET_DIR="$TASK_TMPDIR/socket"
PGPORT_NUMBER=55446
mkdir -p "$PGSOCKET_DIR"

cleanup() {
  /opt/homebrew/opt/postgresql@17/bin/pg_ctl -D "$PGDATA_DIR" -m fast stop >/dev/null 2>&1 || true
  rm -rf "$TASK_TMPDIR"
}
trap cleanup EXIT INT TERM

/opt/homebrew/opt/postgresql@17/bin/initdb -D "$PGDATA_DIR" --no-locale --encoding=UTF8 -U postgres >/dev/null
/opt/homebrew/opt/postgresql@17/bin/pg_ctl -D "$PGDATA_DIR" -l "$TASK_TMPDIR/postgres.log" \
  -o "-F -p $PGPORT_NUMBER -k $PGSOCKET_DIR" start >/dev/null
LOCAL_DB_URL="postgresql://postgres@/postgres?host=$PGSOCKET_DIR&port=$PGPORT_NUMBER"

/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL' >/dev/null
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema auth;
create schema extensions;
create extension pgcrypto with schema extensions;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable
as $$select coalesce(
  nullif(current_setting('request.jwt.claim.sub',true),'')::uuid,
  (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid
)$$;
create function auth.role() returns text language sql stable
as $$select coalesce(
  nullif(current_setting('request.jwt.claim.role',true),''),
  nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role'
)$$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid(), auth.role() to anon, authenticated, service_role;
drop schema public cascade;
SQL

/opt/homebrew/opt/libpq/bin/pg_dump "$CASH_SUPABASE_DB_URL" --schema=public --section=pre-data --no-owner \
  | /opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off >/dev/null
/opt/homebrew/opt/libpq/bin/pg_dump "$CASH_SUPABASE_DB_URL" --schema=public --section=data --data-only --column-inserts --no-owner --no-privileges \
  | /opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off >/dev/null
/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL' >/dev/null
insert into auth.users(id)
select distinct user_id from public.home_accounts
union select distinct user_id from public.home_fixed_month_items
union select distinct user_id from public.home_external_transaction_requests
union select distinct user_id from public.home_card_instruments
on conflict do nothing;
SQL
/opt/homebrew/opt/libpq/bin/pg_dump "$CASH_SUPABASE_DB_URL" --schema=public --section=post-data --no-owner --no-privileges \
  | /opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off >/dev/null

/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL' >/dev/null
begin;
\ir supabase-update-20260821-fixed-month-delete-boundary.sql
do $inside_migration$
begin
  if to_regclass('public.home_fixed_month_item_delete_authorizations') is null
     or to_regprocedure('public.home_delete_fixed_month_item_core(uuid,uuid,text)') is null
     or not exists (
       select 1 from pg_constraint
       where conrelid='public.home_fixed_month_items'::regclass
         and conname='home_fixed_month_items_user_id_fkey' and confdeltype='r'
     )
     or not exists (
       select 1 from pg_trigger
       where tgrelid='public.home_fixed_month_items'::regclass
         and tgname='zz_home_fixed_month_items_delete_contract_guard'
     ) then
    raise exception 'PHASEB2_MIGRATION_TRANSACTIONAL_APPLY_INVALID';
  end if;
end;
$inside_migration$;
rollback;
SQL
/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -Atc "
do \$after_migration_rollback\$
begin
  if to_regclass('public.home_fixed_month_item_delete_authorizations') is not null
     or to_regprocedure('public.home_delete_fixed_month_item_core(uuid,uuid,text)') is not null
     or exists (
       select 1 from pg_trigger
       where tgrelid='public.home_fixed_month_items'::regclass
         and tgname='zz_home_fixed_month_items_delete_contract_guard'
     )
     or not exists (
       select 1 from pg_constraint
       where conrelid='public.home_fixed_month_items'::regclass
         and conname='home_fixed_month_items_user_id_fkey' and confdeltype='c'
     ) then
    raise exception 'PHASEB2_MIGRATION_ROLLBACK_RESIDUE';
  end if;
end;
\$after_migration_rollback\$;
select 'PHASEB2_MIGRATION_FULL_ROLLBACK_PASS|8';"

/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
  -f supabase-update-20260821-fixed-month-delete-boundary.sql >/dev/null
/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
  -f supabase-update-20260821-fixed-month-delete-boundary.sql >/dev/null
/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -Atc "
do \$double_apply\$
begin
  if (select count(*) from pg_class where oid='public.home_fixed_month_item_delete_authorizations'::regclass)<>1
     or (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='home_delete_fixed_month_item_core')<>1
     or (select count(*) from pg_trigger where tgrelid='public.home_fixed_month_items'::regclass
         and tgname='zz_home_fixed_month_items_delete_contract_guard')<>1
     or (select count(*) from pg_policy where polrelid='public.home_fixed_month_items'::regclass
         and polname in ('home_fixed_month_items_user_select','home_fixed_month_items_user_insert','home_fixed_month_items_user_update'))<>3
     or exists(select 1 from pg_policy where polrelid='public.home_fixed_month_item_delete_authorizations'::regclass)
     or (select count(*) from pg_constraint where conrelid='public.home_fixed_month_items'::regclass
         and conname='home_fixed_month_items_user_id_fkey' and confdeltype='r')<>1 then
    raise exception 'PHASEB2_MIGRATION_DOUBLE_APPLY_DUPLICATE_OR_CONTRACT_ERROR';
  end if;
end;
\$double_apply\$;
select 'PHASEB2_MIGRATION_DOUBLE_APPLY_PASS|8';"

MATRIX_OUTPUT=$(/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL'
begin;
\ir supabase-test-20260821-fixed-month-delete-rollback.sql
rollback;
SQL
)
print -r -- "$MATRIX_OUTPUT" | rg 'PHASEB_DELETE_ROLLBACK_MATRIX_PASS'

/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -Atc "
do \$post_matrix\$
begin
  if exists(select 1 from public.home_fixed_month_item_delete_authorizations) then
    raise exception 'PHASEB2_AUTHORIZATION_RESIDUE_AFTER_MATRIX';
  end if;
  if exists(select 1 from public.home_fixed_month_items where id::text like 'b2100000-%') then
    raise exception 'PHASEB2_ITEM_RESIDUE_AFTER_MATRIX';
  end if;
  if exists(select 1 from auth.users where id::text like 'b2100000-%') then
    raise exception 'PHASEB2_USER_RESIDUE_AFTER_MATRIX';
  end if;
end;
\$post_matrix\$;
select 'PHASEB2_DELETE_POST_MATRIX_RESIDUE_ZERO|3';"

IMMUTABILITY_OUTPUT=$(/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -A -t \
  -v ON_ERROR_STOP=1 -P pager=off \
  -f supabase-update-20260802-external-transaction-immutability-rollback-tests.sql)
print -r -- "$IMMUTABILITY_OUTPUT" | rg -x '24'
print -r -- "$IMMUTABILITY_OUTPUT" | rg -x '0'
print 'PHASEB2_EXTERNAL_IMMUTABILITY_REGRESSION_PASS|24'

/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL' >/dev/null
insert into auth.users(id) values ('b2110000-0000-4000-8000-000000000003') on conflict do nothing;
insert into public.home_fixed_month_items(
  id,user_id,month_key,currency,direction,name,amount,status,note,accounting_scope
) values
  ('b2110000-0000-4000-8000-000000000001','8596a708-d99f-4264-8f8c-5b89af9254b6','2098-01','JPY','income','Phase B concurrent target',1,'unpaid','phaseb','household'),
  ('b2110000-0000-4000-8000-000000000002','8596a708-d99f-4264-8f8c-5b89af9254b6','2098-01','JPY','income','Phase B concurrent control',1,'unpaid','phaseb','household'),
  ('b2110000-0000-4000-8000-000000000004','8596a708-d99f-4264-8f8c-5b89af9254b6','2098-01','JPY','income','Phase B concurrent item A',1,'unpaid','phaseb2','household'),
  ('b2110000-0000-4000-8000-000000000005','8596a708-d99f-4264-8f8c-5b89af9254b6','2098-01','JPY','income','Phase B concurrent item B',1,'unpaid','phaseb2','household'),
  ('b2110000-0000-4000-8000-000000000006','8596a708-d99f-4264-8f8c-5b89af9254b6','2098-01','JPY','income','Phase B concurrent actor A',1,'unpaid','phaseb2','household'),
  ('b2110000-0000-4000-8000-000000000007','b2110000-0000-4000-8000-000000000003','2098-01','JPY','income','Phase B concurrent actor B',1,'unpaid','phaseb2','household'),
  ('b2110000-0000-4000-8000-000000000008','8596a708-d99f-4264-8f8c-5b89af9254b6','2098-01','JPY','income','Phase B aborted connection',1,'unpaid','phaseb2','household');
SQL

AUTH_SQL="select set_config('request.jwt.claim.sub','8596a708-d99f-4264-8f8c-5b89af9254b6',true); select set_config('request.jwt.claim.role','authenticated',true); set local lock_timeout='10s'; set local statement_timeout='20s';"
DELETE_SQL="$AUTH_SQL select public.home_delete_fixed_month_item('b2110000-0000-4000-8000-000000000001');"

/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
  -c "begin; $DELETE_SQL select pg_sleep(2); commit;" >"$TASK_TMPDIR/delete-a.log" 2>&1 &
SESSION_A=$!
sleep 0.25
/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
  -c "$DELETE_SQL" >"$TASK_TMPDIR/delete-b.log" 2>&1 &
SESSION_B=$!
wait $SESSION_A
wait $SESSION_B

rg -q 'HOME_FIXED_ITEM_DELETED' "$TASK_TMPDIR/delete-a.log"
rg -q 'HOME_FIXED_ITEM_ALREADY_ABSENT' "$TASK_TMPDIR/delete-b.log"

DELETE_A_SQL="$AUTH_SQL select public.home_delete_fixed_month_item('b2110000-0000-4000-8000-000000000004');"
DELETE_B_SQL="$AUTH_SQL select public.home_delete_fixed_month_item('b2110000-0000-4000-8000-000000000005');"
/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "$DELETE_A_SQL" >"$TASK_TMPDIR/item-a.log" 2>&1 &
SESSION_C=$!
/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "$DELETE_B_SQL" >"$TASK_TMPDIR/item-b.log" 2>&1 &
SESSION_D=$!
wait $SESSION_C
wait $SESSION_D
rg -q 'HOME_FIXED_ITEM_DELETED' "$TASK_TMPDIR/item-a.log"
rg -q 'HOME_FIXED_ITEM_DELETED' "$TASK_TMPDIR/item-b.log"

AUTH_OTHER_SQL="select set_config('request.jwt.claim.sub','b2110000-0000-4000-8000-000000000003',true); select set_config('request.jwt.claim.role','authenticated',true); set local lock_timeout='10s'; set local statement_timeout='20s';"
/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "$AUTH_SQL select public.home_delete_fixed_month_item('b2110000-0000-4000-8000-000000000006');" >"$TASK_TMPDIR/actor-a.log" 2>&1 &
SESSION_E=$!
/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "$AUTH_OTHER_SQL select public.home_delete_fixed_month_item('b2110000-0000-4000-8000-000000000007');" >"$TASK_TMPDIR/actor-b.log" 2>&1 &
SESSION_F=$!
wait $SESSION_E
wait $SESSION_F
rg -q 'HOME_FIXED_ITEM_DELETED' "$TASK_TMPDIR/actor-a.log"
rg -q 'HOME_FIXED_ITEM_DELETED' "$TASK_TMPDIR/actor-b.log"

/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
  -c "begin; $AUTH_SQL select public.home_delete_fixed_month_item('b2110000-0000-4000-8000-000000000008'); select pg_sleep(30); commit;" >"$TASK_TMPDIR/abort.log" 2>&1 &
SESSION_ABORT=$!
ABORT_REACHED_SLEEP=false
for _ in {1..40}; do
  if [[ "$(/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -Atc "
    select count(*) from pg_catalog.pg_stat_activity
    where pid<>pg_backend_pid() and wait_event_type='Timeout' and wait_event='PgSleep';")" -ge 1 ]]; then
    ABORT_REACHED_SLEEP=true
    break
  fi
  sleep 0.1
done
[[ "$ABORT_REACHED_SLEEP" = true ]]
kill "$SESSION_ABORT"
wait "$SESSION_ABORT" 2>/dev/null || true

/opt/homebrew/opt/libpq/bin/psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -Atc "
do \$verify\$
begin
  if exists(select 1 from public.home_fixed_month_items where id='b2110000-0000-4000-8000-000000000001') then
    raise exception 'PHASEB_DELETE_CONCURRENT_TARGET_STILL_EXISTS';
  end if;
  if not exists(select 1 from public.home_fixed_month_items where id='b2110000-0000-4000-8000-000000000002') then
    raise exception 'PHASEB_DELETE_CONCURRENT_CONTROL_CHANGED';
  end if;
  if exists(select 1 from public.home_fixed_month_items where id in (
    'b2110000-0000-4000-8000-000000000004','b2110000-0000-4000-8000-000000000005',
    'b2110000-0000-4000-8000-000000000006','b2110000-0000-4000-8000-000000000007'
  )) then
    raise exception 'PHASEB2_PARALLEL_TARGET_REMAINS';
  end if;
  if not exists(select 1 from public.home_fixed_month_items where id='b2110000-0000-4000-8000-000000000008') then
    raise exception 'PHASEB2_ABORTED_CONNECTION_ITEM_NOT_ROLLED_BACK';
  end if;
  if exists(select 1 from public.home_fixed_month_item_delete_authorizations) then
    raise exception 'PHASEB2_CONCURRENCY_AUTHORIZATION_RESIDUE';
  end if;
end;
\$verify\$;
select 'PHASEB2_DELETE_LOCAL_CONCURRENCY_AND_ABORT_PASS|14';"
