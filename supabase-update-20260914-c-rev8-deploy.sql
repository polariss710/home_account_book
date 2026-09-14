-- Authorized C rev8 deployment; schema only, no fixtures.
\set ON_ERROR_STOP on
begin;
set local lock_timeout='3s';
set local statement_timeout='60s';
do $baseline$ begin
  if (select md5(pg_get_functiondef(18474))) is distinct from 'a14039d661e8533e795c91faeb93597b' then raise exception 'C_BASELINE_DRIFT_home_generate_fixed_month'; end if;
  if (select md5(pg_get_functiondef(18581))) is distinct from 'b9f7d111c4993465b2187dbd6df62f4b' then raise exception 'C_BASELINE_DRIFT_home_sync_fixed_month_items'; end if;
  if (select md5(pg_get_functiondef(18626))) is distinct from 'de0a914f36c30c8db034bd04d9fbb4bc' then raise exception 'C_BASELINE_DRIFT_home_check_fixed_paid_balance'; end if;
  if (select md5(pg_get_functiondef(19683))) is distinct from 'b7d924f323d84e68c414d799439995cf' then raise exception 'C_BASELINE_DRIFT_home_assign_accounting_scope'; end if;
  if (select md5(pg_get_functiondef(18617))) is distinct from 'fc04c725c24ccd3e43ef6e2fb668c428' then raise exception 'C_BASELINE_DRIFT_home_create_fixed_transfer'; end if;
  if (select md5(pg_get_functiondef(18631))) is distinct from 'e5b0ba745054593cba558275b654ffbe' then raise exception 'C_BASELINE_DRIFT_home_fixed_settlement_status'; end if;
  if (select md5(pg_get_functiondef(18470))) is distinct from '2086dc6ba92c36114bd5175dc8f385f1' then raise exception 'C_BASELINE_DRIFT_home_get_fixed_month_page'; end if;
  if (select md5(pg_get_functiondef(19212))) is distinct from '9a3306b0c28f1a7039dc830246dc1fad' then raise exception 'C_BASELINE_DRIFT_home_settle_fixed_advance_repayment'; end if;
  if (select md5(pg_get_functiondef(18627))) is distinct from 'f828df50947b0306140f8f3ef2e11ce7' then raise exception 'C_BASELINE_DRIFT_home_reset_plain_fixed_expenses_if_deficit'; end if;
  if (select md5(pg_get_functiondef(21382))) is distinct from 'f25578b211be192e59a4108af76ece8b' then raise exception 'C_BASELINE_DRIFT_home_guard_projection_linked_fixed_item'; end if;
  if (select md5(pg_get_functiondef(19211))) is distinct from 'b5d40b34f45e21149e54017904da9255' then raise exception 'C_BASELINE_DRIFT_home_create_fixed_advance_payment'; end if;
  if (select md5(pg_get_functiondef(18615))) is distinct from '3399fa34598cd0c9ca63aed01bfa770f' then raise exception 'C_BASELINE_DRIFT_home_update_fixed_month_item_status'; end if;
  if (select md5(pg_get_functiondef(18616))) is distinct from '21cbffacdc60fd6e3cde575615c229a6' then raise exception 'C_BASELINE_DRIFT_home_update_fixed_month_items_status'; end if;
  if (select md5(pg_get_functiondef(22920))) is distinct from '876ce6ba9abdd2212789ce2d72f3bca1' then raise exception 'C_BASELINE_DRIFT_home_guard_fixed_month_item_delete_contract'; end if;
  if (select md5(pg_get_functiondef(18618))) is distinct from '04817c41dedc86167bf7de663353f584' then raise exception 'C_BASELINE_DRIFT_home_delete_fixed_month_item'; end if;
  if (select md5(pg_get_functiondef(24153))) is distinct from '07ccde44caff3410ad3d83afe55c4df8' then raise exception 'C_BASELINE_DRIFT_home_confirm_projection_fixed_item_status'; end if;
  if (select md5(pg_get_functiondef(24170))) is distinct from 'ec8aafb1d75ba80d0347d6aa7cde0217' then raise exception 'C_BASELINE_DRIFT_home_delete_fixed_month_item_core'; end if;
  if (select md5(pg_get_functiondef(18619))) is distinct from '5aea2b7fe9c6de760bae864ca331820f' then raise exception 'C_BASELINE_DRIFT_home_delete_jpy_transaction'; end if;
end $baseline$;
\ir supabase-update-20260914-c-rev8-body.sql
commit;
