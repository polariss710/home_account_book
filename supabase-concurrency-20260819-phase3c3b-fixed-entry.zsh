#!/bin/zsh
set -euo pipefail

[[ -n "${CASH_SUPABASE_DB_URL:-}" ]] || { print -u2 'CASH_SUPABASE_DB_URL is required'; exit 2; }

TASK_TMPDIR=$(mktemp -d /private/tmp/phase3c3b-home-concurrency.XXXXXX)
PGDATA_DIR="$TASK_TMPDIR/pgdata"
PGSOCKET_DIR="$TASK_TMPDIR/socket"
PGPORT_NUMBER=55441
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
  -c 'begin' -f supabase-update-20260819-phase3c3b-fixed-entry.sql -c 'commit' >/dev/null
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c \
  "update public.home_card_instruments set is_school_fixed_route_enabled=true,version=version+1 where id='9b27347e-2dce-4caf-bac0-67f053ef6c3b';" >/dev/null

FIXED_WRITER_SQL="select set_config('request.jwt.claim.role','service_role',true); select public.home_create_external_fixed_transaction_request('8596a708-d99f-4264-8f8c-5b89af9254b6','aozora_school','c33d0000-0000-4000-8000-000000000001','school_expense_records','c33d0000-0000-4000-8000-000000000101','expense_paid','expense','9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-01-09','2099-01-01','2099-01-01','2099-01-25',6400,'JPY','phase3c3b:home:concurrency','local fixed concurrency','',jsonb_build_object('external_source','aozora_school','external_reference_type','school_expense_records','external_reference_id','c33d0000-0000-4000-8000-000000000101','request_type','expense_paid','transaction_type','expense','payment_route','fixed_credit_card','card_instrument_id','9b27347e-2dce-4caf-bac0-67f053ef6c3b','charge_date','2099-01-09','suggested_fixed_month','2099-01-01','target_fixed_month','2099-01-01','funding_date','2099-01-25','school_attempt_payload_fingerprint',repeat('d',64)));"
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "begin; $FIXED_WRITER_SQL select pg_sleep(2); commit;" >"$TASK_TMPDIR/home-writer-a.log" 2>&1 &
SESSION_A=$!
sleep 0.25
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "$FIXED_WRITER_SQL" >"$TASK_TMPDIR/home-writer-b.log" 2>&1 &
SESSION_B=$!
wait $SESSION_A
wait $SESSION_B

psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -Atc "
do \$verify\$
begin
  if (select count(*) from public.home_external_transaction_requests where idempotency_key='phase3c3b:home:concurrency')<>1
     or not exists(select 1 from public.home_external_transaction_requests where idempotency_key='phase3c3b:home:concurrency' and payment_route='fixed_credit_card' and status='pending' and account_id is null and funding_account_id is null)
     or exists(select 1 from public.home_external_fixed_payment_projections where external_request_id=(select id from public.home_external_transaction_requests where idempotency_key='phase3c3b:home:concurrency')) then
    raise exception 'PHASE3C3B_HOME_LOCAL_CONCURRENCY_STATE_INVALID';
  end if;
end;
\$verify\$;
select 'PHASE3C3B_HOME_LOCAL_TWO_SESSION_CONCURRENCY_PASS';"
