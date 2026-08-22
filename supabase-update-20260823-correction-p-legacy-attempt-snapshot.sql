-- Phase E-Compat-Rapid: admit the one historical snapshot shape that predates
-- School attempt evidence embedding. Modern snapshots remain strictly bound to
-- both the attempt id and the payload fingerprint.

begin;

do $migration$
declare
  v_signature constant text :=
    'public.home_prepare_external_transaction_correction_p_core(uuid,uuid,uuid,uuid,uuid,text,uuid)';
  v_oid oid;
  v_definition text;
  v_after_definition text;
  v_old constant text := $old$
     or v_request.payload_snapshot->>'school_attempt_id' is distinct from p_school_attempt_id::text
     or v_request.payload_snapshot->>'school_attempt_payload_fingerprint' is distinct from p_school_fingerprint
$old$;
  v_new constant text := $new$
     or (
          (v_request.payload_snapshot ? 'school_attempt_id')
            <> (v_request.payload_snapshot ? 'school_attempt_payload_fingerprint')
          or (
            (v_request.payload_snapshot ? 'school_attempt_id')
            and (v_request.payload_snapshot ? 'school_attempt_payload_fingerprint')
            and (
              v_request.payload_snapshot->>'school_attempt_id' is distinct from p_school_attempt_id::text
              or v_request.payload_snapshot->>'school_attempt_payload_fingerprint' is distinct from p_school_fingerprint
            )
          )
        )
$new$;
  v_owner oid;
  v_security_definer boolean;
  v_volatility "char";
  v_parallel "char";
  v_config text[];
  v_acl aclitem[];
begin
  select to_regprocedure(v_signature)::oid into v_oid;
  if v_oid is null then
    raise exception 'HOME_CORRECTION_COMPAT_TARGET_NOT_FOUND';
  end if;

  select pg_get_functiondef(p.oid),p.proowner,p.prosecdef,p.provolatile,
         p.proparallel,p.proconfig,p.proacl
  into v_definition,v_owner,v_security_definer,v_volatility,v_parallel,v_config,v_acl
  from pg_proc p
  where p.oid=v_oid;

  if (length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old)<>1 then
    raise exception 'HOME_CORRECTION_COMPAT_EXPECTED_GUARD_NOT_UNIQUE';
  end if;
  if v_definition like '%<> (v_request.payload_snapshot ? ''school_attempt_payload_fingerprint'')%' then
    raise exception 'HOME_CORRECTION_COMPAT_ALREADY_APPLIED';
  end if;

  execute replace(v_definition,v_old,v_new);

  select pg_get_functiondef(p.oid) into v_after_definition
  from pg_proc p
  where p.oid=to_regprocedure(v_signature)::oid;

  if v_after_definition not like '%<> (v_request.payload_snapshot ? ''school_attempt_payload_fingerprint'')%'
     or v_after_definition like '%'||v_old||'%' then
    raise exception 'HOME_CORRECTION_COMPAT_GUARD_REWRITE_FAILED';
  end if;
  if exists (
    select 1
    from pg_proc p
    where p.oid=to_regprocedure(v_signature)::oid
      and (p.proowner is distinct from v_owner
        or p.prosecdef is distinct from v_security_definer
        or p.provolatile is distinct from v_volatility
        or p.proparallel is distinct from v_parallel
        or p.proconfig is distinct from v_config
        or p.proacl is distinct from v_acl)
  ) then
    raise exception 'HOME_CORRECTION_COMPAT_FUNCTION_METADATA_CHANGED';
  end if;
end;
$migration$;

commit;

select
  md5(pg_get_functiondef(
    'public.home_prepare_external_transaction_correction_p_core(uuid,uuid,uuid,uuid,uuid,text,uuid)'::regprocedure
  )) as prepare_core_definition_md5,
  p.prosecdef as security_definer,
  p.provolatile as volatility,
  p.proparallel as parallel_safety,
  p.proconfig as function_config
from pg_proc p
where p.oid='public.home_prepare_external_transaction_correction_p_core(uuid,uuid,uuid,uuid,uuid,text,uuid)'::regprocedure;
