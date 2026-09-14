\set ON_ERROR_STOP on
begin;
set local lock_timeout='3s';
set local statement_timeout='60s';
\ir supabase-test-20260914-c-rev8-body.sql
rollback;
