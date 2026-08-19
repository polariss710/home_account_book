#!/bin/zsh
set -euo pipefail

[[ -n "${CASH_SUPABASE_DB_URL:-}" ]] || { print -u2 'CASH_SUPABASE_DB_URL is required'; exit 2; }

TASK_TMPDIR=$(mktemp -d /private/tmp/phase3e-home-concurrency.XXXXXX)
PGDATA_DIR="$TASK_TMPDIR/pgdata"
PGSOCKET_DIR="$TASK_TMPDIR/socket"
PGPORT_NUMBER=55444
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
  -c 'begin' -f supabase-update-20260819-phase3e-card-statement.sql -c 'commit' >/dev/null

psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL' >/dev/null
update public.home_card_instruments
set is_school_fixed_route_enabled=true,version=version+1
where id='9b27347e-2dce-4caf-bac0-67f053ef6c3b';
insert into public.home_fixed_month_items(
  id,user_id,template_id,month_key,currency,direction,name,amount,status,
  payment_group,due_date,note,accounting_scope
)
select x.id,c.user_id,c.household_statement_template_id,x.month_key,'JPY','expense',
  'Phase 3E household fixture',80000,'unpaid','邮局卡',x.due_date,'','household'
from public.home_card_instruments c
cross join (values
 ('e3100000-0000-4000-8000-000000000101'::uuid,'2099-01','2099-01-25'::date),
 ('e3100000-0000-4000-8000-000000000102'::uuid,'2099-02','2099-02-25'::date),
 ('e3100000-0000-4000-8000-000000000103'::uuid,'2099-03','2099-03-25'::date),
 ('e3100000-0000-4000-8000-000000000104'::uuid,'2099-04','2099-04-25'::date)
) x(id,month_key,due_date)
where c.id='9b27347e-2dce-4caf-bac0-67f053ef6c3b';
SQL

AUTH_PREFIX="select set_config('request.jwt.claim.sub','8596a708-d99f-4264-8f8c-5b89af9254b6',true); select set_config('request.jwt.claim.role','authenticated',true); set local lock_timeout='10s'; set local statement_timeout='20s';"

# confirm/confirm: one transition, one revision, exact concurrent replay.
CONFIRM_JAN="$AUTH_PREFIX select public.home_confirm_card_statement('9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-01-01',100000,0,'phase3e:concurrency:jan');"
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "begin; $CONFIRM_JAN select pg_sleep(2); commit;" >"$TASK_TMPDIR/jan-a.log" 2>&1 &
SESSION_A=$!
sleep 0.25
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "$CONFIRM_JAN" >"$TASK_TMPDIR/jan-b.log" 2>&1 &
SESSION_B=$!
wait $SESSION_A
wait $SESSION_B

# confirm/reopen: reopen waits for confirm, then performs the next legal version.
CONFIRM_FEB="$AUTH_PREFIX select public.home_confirm_card_statement('9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-02-01',100000,0,'phase3e:concurrency:feb:confirm');"
REOPEN_FEB="$AUTH_PREFIX select public.home_reopen_card_statement('9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-02-01',1,'phase3e:concurrency:feb:reopen','concurrent reopen');"
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "begin; $CONFIRM_FEB select pg_sleep(2); commit;" >"$TASK_TMPDIR/feb-confirm.log" 2>&1 &
SESSION_A=$!
sleep 0.25
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "$REOPEN_FEB" >"$TASK_TMPDIR/feb-reopen.log" 2>&1 &
SESSION_B=$!
wait $SESSION_A
wait $SESSION_B

# Prepare one March request. Approve first; concurrent confirm must include it.
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL' >/dev/null
select set_config('request.jwt.claim.role','service_role',false);
select public.home_create_external_fixed_transaction_request(
 '8596a708-d99f-4264-8f8c-5b89af9254b6','aozora_school','e3100000-0000-4000-8000-000000000401',
 'school_expense_records','e3100000-0000-4000-8000-000000000501','expense_paid','expense',
 '9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-03-09','2099-03-01','2099-03-01','2099-03-25',
 33000,'JPY','phase3e:concurrency:march:request','March School fixture','',jsonb_build_object(
  'external_source','aozora_school','external_reference_type','school_expense_records',
  'external_reference_id','e3100000-0000-4000-8000-000000000501','request_type','expense_paid',
  'transaction_type','expense','payment_route','fixed_credit_card',
  'card_instrument_id','9b27347e-2dce-4caf-bac0-67f053ef6c3b','charge_date','2099-03-09',
  'suggested_fixed_month','2099-03-01','target_fixed_month','2099-03-01','funding_date','2099-03-25',
  'year_month','2099-03','school_attempt_payload_fingerprint',repeat('c',64)
 ));
SQL
APPROVE_MAR="$AUTH_PREFIX select public.home_approve_external_fixed_transaction_request((select id from public.home_external_transaction_requests where idempotency_key='phase3e:concurrency:march:request'));"
CONFIRM_MAR="$AUTH_PREFIX select public.home_confirm_card_statement('9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-03-01',100000,0,'phase3e:concurrency:march:confirm');"
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "begin; $APPROVE_MAR select pg_sleep(2); commit;" >"$TASK_TMPDIR/mar-approve.log" 2>&1 &
SESSION_A=$!
sleep 0.25
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "$CONFIRM_MAR" >"$TASK_TMPDIR/mar-confirm.log" 2>&1 &
SESSION_B=$!
wait $SESSION_A
wait $SESSION_B

# Confirm first; a genuinely new April request must wait and then fail closed.
CONFIRM_APR="$AUTH_PREFIX select public.home_confirm_card_statement('9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-04-01',100000,0,'phase3e:concurrency:april:confirm');"
CREATE_APR="select set_config('request.jwt.claim.role','service_role',true); set local lock_timeout='10s'; set local statement_timeout='20s'; select public.home_create_external_fixed_transaction_request('8596a708-d99f-4264-8f8c-5b89af9254b6','aozora_school','e3100000-0000-4000-8000-000000000402','school_expense_records','e3100000-0000-4000-8000-000000000502','expense_paid','expense','9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-04-09','2099-04-01','2099-04-01','2099-04-25',34000,'JPY','phase3e:concurrency:april:request','April late fixture','',jsonb_build_object('external_source','aozora_school','external_reference_type','school_expense_records','external_reference_id','e3100000-0000-4000-8000-000000000502','request_type','expense_paid','transaction_type','expense','payment_route','fixed_credit_card','card_instrument_id','9b27347e-2dce-4caf-bac0-67f053ef6c3b','charge_date','2099-04-09','suggested_fixed_month','2099-04-01','target_fixed_month','2099-04-01','funding_date','2099-04-25','year_month','2099-04','school_attempt_payload_fingerprint',repeat('d',64)));"
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "begin; $CONFIRM_APR select pg_sleep(2); commit;" >"$TASK_TMPDIR/apr-confirm.log" 2>&1 &
SESSION_A=$!
sleep 0.25
psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -c "$CREATE_APR" >"$TASK_TMPDIR/apr-create.log" 2>&1 &
SESSION_B=$!
wait $SESSION_A
wait $SESSION_B

psql "$LOCAL_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -Atc "
do \$verify\$
begin
  if (select count(*) from public.home_card_statement_cycles where target_fixed_month='2099-01-01' and amount_status='confirmed' and version=1)<>1
     or (select count(*) from public.home_card_statement_cycle_revisions where operation_idempotency_key='phase3e:concurrency:jan')<>1 then
    raise exception 'PHASE3E_CONCURRENT_CONFIRM_STATE_INVALID';
  end if;
  if (select count(*) from public.home_card_statement_cycles where target_fixed_month='2099-02-01' and amount_status='pending' and version=2)<>1
     or (select count(*) from public.home_card_statement_cycle_revisions r join public.home_card_statement_cycles c on c.id=r.cycle_id where c.target_fixed_month='2099-02-01')<>2
     or (select amount from public.home_fixed_month_items where id='e3100000-0000-4000-8000-000000000102')<>80000 then
    raise exception 'PHASE3E_CONCURRENT_CONFIRM_REOPEN_STATE_INVALID';
  end if;
  if (select status from public.home_external_transaction_requests where idempotency_key='phase3e:concurrency:march:request')<>'approved'
     or (select school_subtotal_amount from public.home_card_statement_cycles where target_fixed_month='2099-03-01')<>33000
     or (select amount from public.home_fixed_month_items where id='e3100000-0000-4000-8000-000000000103')<>67000 then
    raise exception 'PHASE3E_CONFIRM_APPROVE_SERIALIZATION_INVALID';
  end if;
  if (select count(*) from public.home_card_statement_cycles where target_fixed_month='2099-04-01' and amount_status='confirmed')<>1
     or exists(select 1 from public.home_external_transaction_requests where idempotency_key='phase3e:concurrency:april:request') then
    raise exception 'PHASE3E_CONFIRM_CREATE_SERIALIZATION_INVALID';
  end if;
end;
\$verify\$;
select 'PHASE3E_HOME_LOCAL_TWO_SESSION_CONCURRENCY_PASS';"
