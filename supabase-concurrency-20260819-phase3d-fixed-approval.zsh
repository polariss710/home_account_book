#!/bin/zsh
set -euo pipefail

[[ -n "${CASH_SUPABASE_DB_URL:-}" ]] || { print -u2 'CASH_SUPABASE_DB_URL is required'; exit 2; }

TASK_TMPDIR=$(mktemp -d /private/tmp/phase3d-home-concurrency.XXXXXX)
PGDATA_DIR="$TASK_TMPDIR/pgdata"
PGSOCKET_DIR="$TASK_TMPDIR/socket"
PGPORT_NUMBER=55443
mkdir -p "$PGSOCKET_DIR"
cleanup() { /opt/homebrew/opt/postgresql@17/bin/pg_ctl -D "$PGDATA_DIR" -m fast stop >/dev/null 2>&1 || true }
trap cleanup EXIT INT TERM

/opt/homebrew/opt/postgresql@17/bin/initdb -D "$PGDATA_DIR" --no-locale --encoding=UTF8 -U postgres >/dev/null
/opt/homebrew/opt/postgresql@17/bin/pg_ctl -D "$PGDATA_DIR" -l "$TASK_TMPDIR/postgres.log" \
  -o "-F -p $PGPORT_NUMBER -k $PGSOCKET_DIR" start >/dev/null
LOCAL_DB_URL="postgresql://postgres@/postgres?host=$PGSOCKET_DIR&port=$PGPORT_NUMBER"

psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL' >/dev/null
create role anon nologin;
create role authenticated nologin;
create role service_role nologin;
create schema auth;
create schema extensions;
create extension pgcrypto with schema extensions;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.role() returns text language sql stable as $$select nullif(current_setting('request.jwt.claim.role',true),'')$$;
drop schema public cascade;
SQL

pg_dump "$CASH_SUPABASE_DB_URL" --schema=public --section=pre-data --no-owner --no-privileges \
  | psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off >/dev/null
pg_dump "$CASH_SUPABASE_DB_URL" --schema=public --section=data --data-only --column-inserts --no-owner --no-privileges \
  | psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off >/dev/null
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL' >/dev/null
insert into auth.users(id)
select distinct user_id from public.home_accounts
union select distinct user_id from public.home_external_transaction_requests
union select distinct user_id from public.home_card_instruments
on conflict do nothing;
SQL
pg_dump "$CASH_SUPABASE_DB_URL" --schema=public --section=post-data --no-owner --no-privileges \
  | psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off >/dev/null

psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off \
  -c 'begin' -f supabase-update-20260819-phase3d-fixed-approval.sql -c 'commit' >/dev/null

psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL' >/dev/null
update public.home_card_instruments
set is_school_fixed_route_enabled=true,version=version+1
where id='9b27347e-2dce-4caf-bac0-67f053ef6c3b';
select set_config('request.jwt.claim.role','service_role',false);
with c as (
  select * from public.home_card_instruments where id='9b27347e-2dce-4caf-bac0-67f053ef6c3b'
), s as (
  select x.* from c cross join lateral public.home_calculate_card_fixed_schedule(c.id,'2099-10-09') x
)
select public.home_create_external_fixed_transaction_request(
  c.user_id,'aozora_school','d3000000-0000-4000-8000-000000000001',
  'school_expense_records','d3000000-0000-4000-8000-000000000101',
  'expense_paid','expense',c.id,'2099-10-09',s.suggested_fixed_month,
  s.suggested_fixed_month,s.funding_date,8101,'JPY','phase3d:concurrency:approve',
  'Phase 3D concurrent approval','',jsonb_build_object(
    'external_source','aozora_school','external_reference_type','school_expense_records',
    'external_reference_id','d3000000-0000-4000-8000-000000000101',
    'request_type','expense_paid','transaction_type','expense','payment_route','fixed_credit_card',
    'card_instrument_id',c.id,'charge_date','2099-10-09','suggested_fixed_month',s.suggested_fixed_month,
    'target_fixed_month',s.suggested_fixed_month,'funding_date',s.funding_date,'year_month','2099-10',
    'school_attempt_payload_fingerprint',repeat('a',64)
  )
) from c,s;
with c as (
  select * from public.home_card_instruments where id='9b27347e-2dce-4caf-bac0-67f053ef6c3b'
), s as (
  select x.* from c cross join lateral public.home_calculate_card_fixed_schedule(c.id,'2099-11-09') x
)
select public.home_create_external_fixed_transaction_request(
  c.user_id,'aozora_school','d3000000-0000-4000-8000-000000000002',
  'school_expense_records','d3000000-0000-4000-8000-000000000102',
  'expense_paid','expense',c.id,'2099-11-09',s.suggested_fixed_month,
  s.suggested_fixed_month,s.funding_date,8201,'JPY','phase3d:concurrency:race',
  'Phase 3D approve reject race','',jsonb_build_object(
    'external_source','aozora_school','external_reference_type','school_expense_records',
    'external_reference_id','d3000000-0000-4000-8000-000000000102',
    'request_type','expense_paid','transaction_type','expense','payment_route','fixed_credit_card',
    'card_instrument_id',c.id,'charge_date','2099-11-09','suggested_fixed_month',s.suggested_fixed_month,
    'target_fixed_month',s.suggested_fixed_month,'funding_date',s.funding_date,'year_month','2099-11',
    'school_attempt_payload_fingerprint',repeat('b',64)
  )
) from c,s;
SQL

APPROVE_SQL="select set_config('request.jwt.claim.sub',(select user_id::text from public.home_external_transaction_requests where idempotency_key='phase3d:concurrency:approve'),true); select public.home_approve_external_fixed_transaction_request((select id from public.home_external_transaction_requests where idempotency_key='phase3d:concurrency:approve'));"
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "begin; $APPROVE_SQL select pg_sleep(2); commit;" >"$TASK_TMPDIR/approve-a.log" 2>&1 &
SESSION_A=$!
sleep 0.25
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "$APPROVE_SQL" >"$TASK_TMPDIR/approve-b.log" 2>&1 &
SESSION_B=$!
wait $SESSION_A
wait $SESSION_B

RACE_APPROVE_SQL="select set_config('request.jwt.claim.sub',(select user_id::text from public.home_external_transaction_requests where idempotency_key='phase3d:concurrency:race'),true); select public.home_approve_external_fixed_transaction_request((select id from public.home_external_transaction_requests where idempotency_key='phase3d:concurrency:race'));"
RACE_REJECT_SQL="select set_config('request.jwt.claim.sub',(select user_id::text from public.home_external_transaction_requests where idempotency_key='phase3d:concurrency:race'),true); select public.home_reject_external_transaction_request((select id from public.home_external_transaction_requests where idempotency_key='phase3d:concurrency:race'),'phase3d race reject');"
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "begin; $RACE_APPROVE_SQL select pg_sleep(2); commit;" >"$TASK_TMPDIR/race-approve.log" 2>&1 &
SESSION_A=$!
sleep 0.25
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "$RACE_REJECT_SQL" >"$TASK_TMPDIR/race-reject.log" 2>&1 &
SESSION_B=$!
wait $SESSION_A
wait $SESSION_B

psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -Atc "
do \$verify\$
declare v_request uuid;
begin
  select id into v_request from public.home_external_transaction_requests where idempotency_key='phase3d:concurrency:approve';
  if not exists(select 1 from public.home_external_transaction_requests where id=v_request and status='approved')
     or (select count(*) from public.home_external_fixed_payment_projections where external_request_id=v_request)<>1
     or (select count(*) from public.home_fixed_month_items i join public.home_external_fixed_payment_projections p on p.fixed_month_item_id=i.id where p.external_request_id=v_request)<>1 then
    raise exception 'PHASE3D_CONCURRENT_APPROVE_STATE_INVALID';
  end if;
  select id into v_request from public.home_external_transaction_requests where idempotency_key='phase3d:concurrency:race';
  if (select status from public.home_external_transaction_requests where id=v_request)<>'approved'
     or (select count(*) from public.home_external_fixed_payment_projections where external_request_id=v_request)<>1 then
    raise exception 'PHASE3D_APPROVE_REJECT_RACE_STATE_INVALID';
  end if;
end;
\$verify\$;
select 'PHASE3D_HOME_LOCAL_TWO_SESSION_CONCURRENCY_PASS';"
