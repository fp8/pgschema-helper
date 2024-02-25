--
-- PostgreSQL database dump
--

-- Dumped from database version 13.12
-- Dumped by pg_dump version 14.5

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: import; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA import;


ALTER SCHEMA import OWNER TO postgres;

--
-- Name: enum_apm_file_key_source; Type: TYPE; Schema: public; Owner: exa_db
--

CREATE TYPE public.enum_apm_file_key_source AS ENUM (
    'processing',
    'cumulative'
);


ALTER TYPE public.enum_apm_file_key_source OWNER TO exa_db;

--
-- Name: enum_apm_file_monitor_status; Type: TYPE; Schema: public; Owner: exa_db
--

CREATE TYPE public.enum_apm_file_monitor_status AS ENUM (
    'OK',
    'MISSING',
    'EXTRA'
);


ALTER TYPE public.enum_apm_file_monitor_status OWNER TO exa_db;

--
-- Name: enum_apm_import_rec_status; Type: TYPE; Schema: public; Owner: exa_db
--

CREATE TYPE public.enum_apm_import_rec_status AS ENUM (
    'OK',
    'MISSING',
    'EXTRA',
    'IGNORE'
);


ALTER TYPE public.enum_apm_import_rec_status OWNER TO exa_db;

--
-- Name: fun_active_rec_source_ref(date); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_active_rec_source_ref(in_rpt_date date) RETURNS TABLE(rec_source_ref character varying)
    LANGUAGE plpgsql
    AS $$

BEGIN

    return query
        -- Fine the latest rec_source_ref to use for the rpt_date
        select distinct on (rec_source_ref) t.rec_source_ref
        from apm_import_rec t
        where t.rpt_date = in_rpt_date
        order by t.rec_source_ref desc, t.modified_on desc
        limit 1;

END
$$;


ALTER FUNCTION public.fun_active_rec_source_ref(in_rpt_date date) OWNER TO exa_db;

--
-- Name: fun_apm_file_monitor(date); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_apm_file_monitor(in_rpt_date date) RETURNS TABLE(source character varying, file_key character varying, file_rpt_date date, current_count integer, expected_count integer, delta integer, rec_source_ref character varying)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_rec_source_ref varchar;

BEGIN
    -- Find the latest rec_source_ref to use for the rpt_date
    select t.rec_source_ref
    into v_rec_source_ref
    from fun_active_rec_source_ref(in_rpt_date) t;

    return query
        with temp_count as (
            select
                max(r.source)::varchar as source,
                t.file_key,
                r.file_key_desc,
                max(coalesce((t.content ->> 'file_rpt_date')::date, t.rpt_date)) as file_rpt_date,
                count(*)::integer as current_count,
                max(r.expected_count)::integer as expected_count
            from apm_import_rec t
                     join ref_apm_file_key r on (r.file_key = t.file_key)
            where t.rec_source_ref = v_rec_source_ref
              and r.monitor_flag = true
              and t.monitor_status in ('OK', 'EXTRA')
            group by t.file_key, r.file_key_desc
        ), temp_delta as (
            select
                t.file_key,
                count(*)::integer as delta
            from apm_import_rec t
                     join ref_apm_file_key r on (r.file_key = t.file_key)
            where t.rec_source_ref = v_rec_source_ref
              and r.monitor_flag = true
              and t.monitor_status in ('EXTRA', 'MISSING')
            group by t.file_key
        )

        select
            t.source,
            t.file_key_desc as file_key,
            t.file_rpt_date,
            t.current_count,
            t.expected_count,
            coalesce(d.delta, 0) as delta,
            v_rec_source_ref as rec_source_ref
        from temp_count t
                 left join temp_delta d on (t.file_key = d.file_key)
        order by t.source, t.file_key;
END
$$;


ALTER FUNCTION public.fun_apm_file_monitor(in_rpt_date date) OWNER TO exa_db;

--
-- Name: fun_apm_file_monitor_detail(date, character varying); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_apm_file_monitor_detail(in_rpt_date date, in_file_key character varying) RETURNS TABLE(file_key character varying, location_name character varying, abi character, monitor_status character varying, rec_source_ref character varying)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_rec_source_ref varchar;

BEGIN

    -- Find the latest rec_source_ref to use for the rpt_date
    select t.rec_source_ref
    into v_rec_source_ref
    from fun_active_rec_source_ref(in_rpt_date) t;

    return query
        select
            in_file_key as file_key,
            (t.content ->> 'location_name')::varchar as location_name,
            r.abi,
            t.monitor_status::varchar,
            t.rec_source_ref
        from apm_import_rec t
                 left join ref_apm_file_loc r on r.location_name = (t.content ->> 'location_name')
        where t.rec_source_ref = v_rec_source_ref
          and t.file_key = upper(in_file_key)
          and t.monitor_status in ('MISSING', 'EXTRA');
END
$$;


ALTER FUNCTION public.fun_apm_file_monitor_detail(in_rpt_date date, in_file_key character varying) OWNER TO exa_db;

--
-- Name: fun_check_position_bond(date); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_check_position_bond(in_rpt_date date) RETURNS TABLE(key character varying, security character varying, abi character varying, desk character varying, book character varying, company character varying, json jsonb)
    LANGUAGE plpgsql
    AS $$
	begin
		RETURN QUERY
		with bond as(
    select distinct on (spr.desk, spr.book, company, spr.security)
    	concat_ws('_', spr."security", b.abi, plr.destination, spr.book )::varchar as key,
    	spr.security,
    	b.abi as abi,
        spr.desk,
        spr.book,
        spr.company,
        spr.json
        from import.sec_pos_rep spr
        left join public.bank b on spr.company = b.code
        join public.position_link_rule plr on spr.book = plr.origin and plr."type" ='DESK'
        join public.position_link_rule plrD on spr.book = plrD.origin and plrD."type" ='BOOK'
    order by spr.desk,
             spr.book,
             spr.company,
             spr.security,
             spr.generatedpk
             )
select * from bond b where b.key not in (select position_key from position p where p.rpt_date = in_rpt_date::date and p.position_type not in ('SWAP','EQUITY'));

	END;
$$;


ALTER FUNCTION public.fun_check_position_bond(in_rpt_date date) OWNER TO exa_db;

--
-- Name: fun_check_position_swap(date); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_check_position_swap(in_rpt_date date) RETURNS TABLE(rownumber bigint, key character varying, tradeid character varying, legtype character varying, company character varying, desk character varying, book character varying, secid character varying, bondbook character varying, json_agg jsonb)
    LANGUAGE plpgsql
    AS $$
	begin
		return QUERY
with swap as (
select 
	row_number() over (partition by tps.tradeid, tps.legtype order by tps.generatedpk::numeric) as rowNumber,
	concat_ws('_', tps.secId, b.abi, plrd.destination, tps.book, tps.tradeid)::varchar as key,
	tps.tradeid,
	tps.legtype,
	tps.company,
	plrd.destination as desk,
	tps.book,
	tps.secId,
	plr.destination as bondBook,
	jsonb_agg(json) as json_agg
from
	import.trade_pl_swap tps
join public.position_link_rule plr on plr.origin = tps.book and plr.type = 'BOOK'
join public.position_link_rule plrd on plrd.origin = tps.desk and plrd.type = 'DESK'
left join public.bank b on tps.company = b.code
group by
	b.abi,
	tps.generatedpk,
	tps.tradeid,
	tps.legtype,
	tps.company,
	tps.desk,
	tps.book,
	tps.secId,
	bondBook,
	plrd.destination
order by generatedpk::numeric)
select * from swap s
where s.key not in (select position_key from position p where p.rpt_date = in_rpt_date::date and p.position_type = 'SWAP');
end;

$$;


ALTER FUNCTION public.fun_check_position_swap(in_rpt_date date) OWNER TO exa_db;

--
-- Name: fun_current_rpt_date(integer); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_current_rpt_date(in_state_id integer DEFAULT 80000) RETURNS TABLE(rpt_date date, display_date date, business_day boolean, prev_business_date date, next_business_date date, state_id integer)
    LANGUAGE plpgsql
    AS $$

BEGIN
    return query
        select
            r.rpt_date,
            r.display_date,
            r.business_day,
            r.prev_business_date,
            r.next_business_date,
            r.state_id
        from fun_get_rpt_date(in_state_id => in_state_id) r
    ;
END
$$;


ALTER FUNCTION public.fun_current_rpt_date(in_state_id integer) OWNER TO exa_db;

--
-- Name: fun_dash_profilo_reddituale(date, character varying); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_dash_profilo_reddituale(in_rpt_date date, in_portfolio_key character varying) RETURNS TABLE(desk character varying, interessimaturati numeric, aggiodisaggio numeric, costoammortizzato numeric, realizedpl numeric, unrealizedpl numeric, initialreserve numeric, finalreserve numeric, currentyieldweight numeric, currentyield numeric, quantitybond numeric)
    LANGUAGE plpgsql
    AS $$

BEGIN
    return query
        with quantityBond as (
            select sum(p2.quantity) as q from position p2
            where p2.rpt_date = in_rpt_date
              and p2.portfolio_key = in_portfolio_key
              and p2.position_type = 'BOND'
              and p2.quantity != 0)
        select p.desk,
               sum(p.ytd_margin_interest_accrual)
               + sum(COALESCE((data -> 'legs' -> 0 ->> 'inflCashFlows')::NUMERIC,0)) 
               + sum(COALESCE((data -> 'legs' -> 1 ->> 'inflCashFlows')::NUMERIC,0))
               as interessiMaturati,
               sum(p.aggioDisaggio)            as aggioDisaggio,
               sum(p.costoAmmortizzato)        as costoAmmortizzato,
               sum(p.realizedpl)               as realizedPl,
               sum(p.unrealizedpl)             as unrealizedPl,
               sum(p.initialReserve)           as initialReserve,
               sum(p.finalReserve)             as finalReserve,               
               sum(p.current_yield_weight)     as currentYieldWeight,
               CASE sum(p.current_yield_weight)
               	WHEN 0 THEN 0
	            ELSE sum(p.current_yield*current_yield_weight)/sum(p.current_yield_weight)
	           END as currentYield,
               (select q from quantityBond) as quantityBond
        from position p
        where p.rpt_date = in_rpt_date and p.portfolio_key = in_portfolio_key
          and p.position_type in ('BOND', 'SWAP')
        group by p.desk
    ;
END
$$;


ALTER FUNCTION public.fun_dash_profilo_reddituale(in_rpt_date date, in_portfolio_key character varying) OWNER TO exa_db;

--
-- Name: fun_get_done_date(); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_get_done_date() RETURNS TABLE(rpt_date date, last_updated timestamp without time zone)
    LANGUAGE plpgsql
    AS $$

BEGIN

    return query
        select r.rpt_date, r.create_on as last_updated
        from ref_rpt_date r
        where r.state_id in (40000, 80000)
        order by r.rpt_date desc;

END
$$;


ALTER FUNCTION public.fun_get_done_date() OWNER TO exa_db;

--
-- Name: fun_get_limiti_emittente(date, character varying); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_get_limiti_emittente(in_rpt_date date DEFAULT NULL::date, in_portfolio_key character varying DEFAULT NULL::character varying) RETURNS TABLE(asset_class_key character varying, used numeric, limite numeric)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_desk varchar;
    v_abi varchar;

BEGIN

    v_desk := (select desk from position where portfolio_key = in_portfolio_key limit 1);
    v_abi := (select abi from position where portfolio_key = in_portfolio_key limit 1);

    return query
        select
            r.asset_class_key as asset_class_key,
            sum(coalesce(p.pn, 0)) as used,
            lv.max as "limit"
        from
            ref_limit r
                join limit_value lv on r.limit_keyl1 = lv.limit_key
                join ref_limit_asset_class a on a.asset_class_key = r.asset_class_key
                join instrument i on i.rpt_date=lv.rpt_date and i.asset_class_key=a.value
                left join position p on p.rpt_date = i.rpt_date
                and p.instrument_key = i.instrument_key
                and p.rpt_date = in_rpt_date
                and p.portfolio_key = in_portfolio_key
                and p.position_type = 'BOND'
                and p.quantity != 0
        where
                lv.rpt_date = in_rpt_date
          and lv.abi = v_abi
          and r.asset_class_key in ('SOVRA', 'EMK', 'IT')
          and r.attribute_class_key is null
          and r.desk = v_desk
        group by r.asset_class_key, lv.max
    ;
END
$$;


ALTER FUNCTION public.fun_get_limiti_emittente(in_rpt_date date, in_portfolio_key character varying) OWNER TO exa_db;

--
-- Name: fun_get_ref_apm_file_key(); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_get_ref_apm_file_key() RETURNS TABLE(source public.enum_apm_file_key_source, file_key character varying, location_name_flag boolean, rpt_date_flag boolean, sort integer)
    LANGUAGE plpgsql
    AS $$

BEGIN
    return query
        select
            t.source,
            t.file_key_desc as file_key,
            t.location_name_flag,
            t.rpt_date_flag,
            t.sort
        from ref_apm_file_key t
        where t.file_key not like 'UNKNOWN%'
        order by
            t.sort desc, t.file_key
    ;
END
$$;


ALTER FUNCTION public.fun_get_ref_apm_file_key() OWNER TO exa_db;

--
-- Name: fun_get_rpt_date(date, integer); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_get_rpt_date(in_rpt_date date DEFAULT NULL::date, in_state_id integer DEFAULT NULL::integer) RETURNS TABLE(rpt_date date, display_date date, business_day boolean, prev_business_date date, next_business_date date, state_id integer, state character varying)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_rpt_date date;

BEGIN

    if in_rpt_date is not NULL then
        v_rpt_date := in_rpt_date;
    elsif in_state_id is not NULL then
        v_rpt_date = (
            select max(r.rpt_date)
            from ref_rpt_date r
            where r.state_id = in_state_id
        );
    else
        v_rpt_date = (
            select max(r.rpt_date)
            from ref_rpt_date r
        );
    end if;

    return query
        select
            r.rpt_date,
            r.display_date,
            r.business_day,
            r.prev_business_date,
            r.next_business_date,
            r.state_id,
            rs.state
        from ref_rpt_date r
                 join ref_state rs on r.state_id = rs.state_id
        where r.rpt_date = v_rpt_date
    ;
END
$$;


ALTER FUNCTION public.fun_get_rpt_date(in_rpt_date date, in_state_id integer) OWNER TO exa_db;

--
-- Name: fun_get_rpt_date_by_int_date(integer); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_get_rpt_date_by_int_date(in_rpt_date integer) RETURNS TABLE(rpt_date date, display_date date, business_day boolean, prev_business_date date, next_business_date date, state_id integer, state character varying)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_rpt_date date;

BEGIN
    v_rpt_date := to_date(in_rpt_date::text, 'YYYYMMDD');

    return query
        select
            r.rpt_date,
            r.display_date,
            r.business_day,
            r.prev_business_date,
            r.next_business_date,
            r.state_id,
            r.state
        from fun_get_rpt_date(in_rpt_date => v_rpt_date) r
    ;
END
$$;


ALTER FUNCTION public.fun_get_rpt_date_by_int_date(in_rpt_date integer) OWNER TO exa_db;

--
-- Name: fun_get_rpt_date_by_state(integer, character varying); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_get_rpt_date_by_state(in_state_id integer DEFAULT NULL::integer, in_state character varying DEFAULT NULL::character varying) RETURNS TABLE(rpt_date date, display_date date, business_day boolean, prev_business_date date, next_business_date date, state_id integer, state character varying)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_state_id integer;

BEGIN

    if in_state_id is not null then
        v_state_id := in_state_id;
    elsif in_state is not null then
        v_state_id = (
            select r.state_id
            from ref_state r
            where r.state = in_state
        );
    else
        -- default to done state
        v_state_id := 80000;
    end if;


    return query
        select
            r.rpt_date,
            r.display_date,
            r.business_day,
            r.prev_business_date,
            r.next_business_date,
            r.state_id,
            r.state
        from fun_get_rpt_date(in_state_id => v_state_id) r
    ;
END
$$;


ALTER FUNCTION public.fun_get_rpt_date_by_state(in_state_id integer, in_state character varying) OWNER TO exa_db;

--
-- Name: fun_get_rpt_date_list(); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_get_rpt_date_list() RETURNS TABLE(rpt_date date, last_updated timestamp without time zone)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_done_on timestamp;
    v_active_state_id int := 40000;
    v_done_state_id int := 80000;

BEGIN
    v_done_on := (
        select max(done_on)
        from ref_rpt_date
        where state_id in (v_active_state_id, v_done_state_id)
    );

    return query
        select
            r.rpt_date,
            v_done_on as last_updated
        from ref_rpt_date r
        where state_id in (v_active_state_id, v_done_state_id)
        order by r.rpt_date desc;

END
$$;


ALTER FUNCTION public.fun_get_rpt_date_list() OWNER TO exa_db;

--
-- Name: fun_get_trades(date, character varying); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_get_trades(in_rpt_date date, in_position_key character varying) RETURNS TABLE(tradekey character varying, company character varying, abi character varying, book character varying, desk character varying, isin character varying, exttradeid character varying, tradedate date, tradeentrydate date, tradestatus character varying, pors character varying, settledate date, notional numeric, cleanprice numeric, executiondatetime timestamp without time zone)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_abi varchar;
    v_desk varchar;
    v_book varchar;
    v_isin varchar;

BEGIN

    -- Retrieve the required abi, desk, book and isin from position table
    select p.abi, p.desk, p.book, p.isin
    into v_abi, v_desk, v_book, v_isin
    from position p
    where p.rpt_date = in_rpt_date
    and p.position_key = in_position_key;

    RETURN QUERY
        select
            th.trade_key,
            th.company,
            th.abi,
            th.book,
            th.desk,
            th.isin,
            th.ext_trade_id,
            th.trade_date,
            th.trade_entry_date,
            th.trade_status,
            th.pors,
            th.settle_date,
            th.notional,
            th.clean_price,
            th.execution_datetime
        from
            public.trade t
            join public.trade_hist th on (t.trade_key = th.trade_key and t.starts_on = th.starts_on)
        where
            t.rpt_date = in_rpt_date
            and th.abi = v_abi
            and th.desk = v_desk
            and th.book = v_book
            and th.isin = v_isin
        ;
END
$$;


ALTER FUNCTION public.fun_get_trades(in_rpt_date date, in_position_key character varying) OWNER TO exa_db;

--
-- Name: fun_reset_rpt_date_state(date); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_reset_rpt_date_state(in_rpt_date date) RETURNS TABLE(state_id integer)
    LANGUAGE plpgsql
    AS $$


/**
Reset the rpt_date for processing.  Only reset if the state are:

- 10000: This is `processing` state and will be reset to `init` [0]
- 40000: This is `active` state and will be rest to `done` [80000]
 */

DECLARE
    v_curr_state_id int;
    v_to_state_id int;
    v_init_state_id int := 0;
    v_processing_state_id int := 10000;
    v_active_state_id int := 40000;
    v_done_state_id int := 80000;

BEGIN
    -- Get current state id from the ref_rpt_date table
    v_curr_state_id := (
        select t.state_id
        from ref_rpt_date t
        where t.rpt_date = in_rpt_date
    );

    -- Raise Error if not exists
    IF v_curr_state_id is null THEN
        raise exception 'Cannot reset state as % rpt_date does not exists', in_rpt_date;
    ELSIF v_curr_state_id = v_processing_state_id THEN
        -- If current state is `processing`, set it to `init`
        select v_init_state_id into v_to_state_id;
    ELSIF v_curr_state_id = v_active_state_id THEN
        -- If current state is `active`, set it to `done`
        select v_done_state_id into v_to_state_id;
    ELSE
        raise exception 'Cannot reset state as current state is %.  Expect it to be 10000 or 40000', v_curr_state_id;
    END IF
    ;

    -- Update state
    update ref_rpt_date
    set state_id = v_to_state_id
    where rpt_date = in_rpt_date;

    -- Return result
    return query
        select v_to_state_id
    ;
END
$$;


ALTER FUNCTION public.fun_reset_rpt_date_state(in_rpt_date date) OWNER TO exa_db;

--
-- Name: fun_view_position(date); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_view_position(in_rpt_date date) RETURNS TABLE(risk_pos_key character varying, position_type character varying, position_key character varying, rpt_date date, abi character varying, book character varying, calc jsonb, created_on timestamp without time zone, currency text, subtype character varying, data jsonb, desk character varying, instrument_key character varying, isin character varying, portfolio_key character varying, quantity numeric, realizedpl double precision, unrealizedpl numeric, exchange character varying, parent_position_key character varying, parent_rpt_date date, pn numeric, mtm numeric, description character varying, residual_life numeric, ytdmargininterestaccrual numeric, aggiodisaggio numeric, costoammortizzato numeric, finalreserve numeric, current_yield numeric, current_yield_weight numeric, cmvigil numeric, asset_class_key character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
        select p.risk_pos_key,
               p.position_type,
               p.position_key,
               p.rpt_date,
               p.abi,
               p.book,
               p.calc,
               p.created_on,
               'EUR'                                                  as currency,
               i.sub_type                                             as subType,
               p.data,
               p.desk,
               p.instrument_key,
               p.isin,
               p.portfolio_key,
               p.quantity,
               (p.data ->> 'ytdrealizedPL')::float                    as realizedpl,
               p.unrealizedpl,
               p.exchange,
               p.parent_position_key,
               p.parent_rpt_date,
               (case
                    when
                            p.book in ('STRATEGICO', 'D_HTC_CA', 'D_D_HDG_HTC', 'D_HTC_FVTPL',
                                       'D_HTCS_FVOCI', 'D_D_HDG_HTCS', 'D_HTCS_FVTPL')
                        then (coalesce((p.calc ->> 'pmc')::numeric, 0) * p.quantity / 100)
                    else (coalesce((p.data ->> 'mtMPrezzoSecco')::numeric, 0) +
                          (coalesce((p.calc ->> 'interestAccrual')::numeric, 0)))
                   end)                                               as pn,
               coalesce((p.data ->> 'mtMPrezzoSecco')::numeric, 0)    as mtm,
               nullif(i.description, i.isin)::varchar(255)            as description,
               i.residual_life                                        as residual_life,
               coalesce((p.calc ->> 'rateiECedole')::numeric, 0)      as ytdMarginInterestAccrual,
               coalesce((p.data ->> 'aggioDisaggio')::numeric, 0)     as aggioDisaggio,
               coalesce((p.calc ->> 'costoAmmortizzato')::numeric, 0) as costoAmmortizzato,
               coalesce((p.data ->> 'reserveOci')::numeric, 0)        as finalReserve,
               coalesce((p.data ->> 'currentYield')::numeric, 0)      as current_yield,
               coalesce(p.quantity::numeric, 0)                       as current_yield_weight,
               coalesce((i.data ->> 'cmVigil')::numeric, 0)           as cmVigil,
               i.asset_class_key                                      as asset_class_key
        from position p
                 join instrument i
                      on p.instrument_key = i.instrument_key and p.rpt_date = i.rpt_date
        where p.position_type = 'BOND'
          and p.rpt_date = in_rpt_date
        union
        select p.risk_pos_key,
               p.position_type,
               p.position_key,
               p.rpt_date,
               p.abi,
               p.book,
               p.calc,
               p.created_on,
               'EUR'                                                                   as currency,
               null                                                                    as subType,
               p.data,
               p.desk,
               p.instrument_key,
               p.isin,
               p.portfolio_key,
               coalesce(p.quantity, 0) * coalesce((p.data ->> 'avgPrice')::numeric, 0) as quantity,
               (p.data ->> 'ytdrealizedPL')::float                                     as realizedpl,
               p.unrealizedpl,
               p.exchange,
               p.parent_position_key,
               p.parent_rpt_date,
               coalesce((p.data ->> 'mktPrice')::numeric, 0) * coalesce(p.quantity, 0) as pn,
               coalesce((p.data ->> 'mktPrice')::numeric, 0) * coalesce(p.quantity, 0) as mtm,
               p.isin::varchar(255)                                                    as description,
               null                                                                    as residual_life,
               0                                                                       as ytdMarginInterestAccrual,
               0                                                                       as aggioDisaggio,
               0                                                                       as costoAmmortizzato,
               0                                                                       as finalReserve,
               0                                                                       as current_yield,
               0                                                                       as current_yield_weight,
               null                                                                    as cmVigil,
               i.asset_class_key                                                       as asset_class_key
        from position p
                 join instrument i
                      on p.instrument_key = i.instrument_key and p.rpt_date = i.rpt_date
        where p.position_type = 'EQUITY'
          and p.rpt_date = in_rpt_date
        union
        select p.risk_pos_key,
               p.position_type,
               left((MAX(ARRAY [p.position_key]))[1],
                    length((MAX(ARRAY [p.position_key]))[1]) - 4)                            as position_key,
               p.rpt_date,
               p.abi,
               p.book,
               (json_build_object('type', (MAX(ARRAY [p.calc ->> 'type']))[1], 'legs',
                                  (json_strip_nulls(json_agg(json_build_object(
                                          'costoAmmortizzato', p.calc ->> 'costoAmmortizzato',
                                          'legId', p.data ->> 'legId', 'eir',
                                          p.calc ->>
                                          'eir'))))))::jsonb                                 as calc,
               (MAX(ARRAY [p.created_on]))
                   [1]                                                                       as created_on,
               'EUR'                                                                         as currency,
               null                                                                          as subType,
               (json_build_object('type', (MAX(ARRAY [p.data ->> 'type']))[1], 'legs',
                                  (json_strip_nulls(json_agg(p.data - 'type')))))::jsonb     as data,
               p.desk,
               p.instrument_key,
               p.isin,
               p.portfolio_key,
               ABS((MAX(ARRAY [p.quantity])
                    filter (where p.data ->> 'legId' = 'P'))[1])                             as quantity,
               sum(p.realizedpl)                                                             as realizedpl,
               sum(p.unrealizedpl)                                                           as unrealizedpl,
               p.exchange,
               (MAX(ARRAY [p.parent_position_key]))[1]                                       as parent_position_key,
               (MAX(ARRAY [p.parent_rpt_date]))[1]                                           as parent_rpt_date,
               sum((p.data ->> 'remMktVal'):: numeric + (p.data ->> 'remAccrInt'):: numeric) as pn,
               sum((p.data ->> 'remMktVal'):: numeric + (p.data ->> 'remAccrInt'):: numeric) as mtm,
               p.isin:: varchar(255)                                                         as description,
               null                                                                          as residual_life,
               sum(coalesce((p.data ->> 'intAccrYTD')::numeric, 0))                          as ytdMarginInterestAccrual,
               0                                                                             as aggioDisaggio,
               sum(coalesce((p.calc ->> 'costoAmmortizzato')::numeric, 0))                   as costoAmmortizzato,
               0                                                                             as finalReserve,
               case when ABS((MAX(ARRAY [(p.data ->> 'remNominal')::numeric]) filter (where p.data ->> 'legId' = 'P'))[1]) != 0
                   then sum(
                       coalesce((p.data ->> 'currentYield')::numeric, 0) * coalesce((p.data ->> 'remNominal')::numeric, 0))
                       / ABS((MAX(ARRAY [(p.data ->> 'remNominal')::numeric]) filter (where p.data ->> 'legId' = 'P'))[1])
                   else 0
               end
                   as current_yield,
               ABS((MAX(ARRAY [(p.data ->> 'remNominal')::numeric]) filter (where p.data ->> 'legId' = 'P'))[1]) as current_yield_weight,
               null                                                                          as cmVigil,
               'SWAP'                                                                        as asset_class_key
        from position p
        where p.position_type = 'SWAP'
          and p.rpt_date = in_rpt_date
        group by p.risk_pos_key, p.position_type, p.rpt_date, p.abi, p.book, p.desk,
                 p.instrument_key, p.isin,
                 p.portfolio_key, p.exchange;
END;
$$;


ALTER FUNCTION public.fun_view_position(in_rpt_date date) OWNER TO exa_db;

--
-- Name: fun_view_position(date, character varying); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.fun_view_position(in_rpt_date date, in_portfolio_key character varying) RETURNS TABLE(risk_pos_key character varying, position_type character varying, position_key character varying, rpt_date date, abi character varying, book character varying, calc jsonb, created_on timestamp without time zone, currency text, data jsonb, desk character varying, instrument_key character varying, isin character varying, portfolio_key character varying, quantity numeric, realizedpl double precision, unrealizedpl numeric, exchange character varying, parent_position_key character varying, parent_rpt_date date, pn numeric, mtm numeric, description character varying, residual_life numeric, ytdmargininterestaccrual numeric, aggiodisaggio numeric, costoammortizzato numeric, finalreserve numeric, current_yield numeric, cmvigil numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
        select p.risk_pos_key,
               p.position_type,
               p.position_key,
               p.rpt_date,
               p.abi,
               p.book,
               p.calc,
               p.created_on,
               'EUR'    as currency,
               p.data,
               p.desk,
               p.instrument_key,
               p.isin,
               p.portfolio_key,
               p.quantity,
               (p.data ->> 'ytdrealizedPL')::float as realizedpl, p.unrealizedpl,
               p.exchange,
               p.parent_position_key,
               p.parent_rpt_date,
               (case
                    when
                            p.book in ('STRATEGICO', 'D_HTC_CA', 'D_D_HDG_HTC', 'D_HTC_FVTPL',
                                       'D_HTCS_FVOCI', 'D_D_HDG_HTCS', 'D_HTCS_FVTPL')
                        then (coalesce((p.calc ->> 'pmc')::numeric, 0) * p.quantity / 100)
                    else (coalesce((p.data ->> 'mtMPrezzoSecco')::numeric, 0) +
                          (coalesce((p.calc ->> 'interestAccrual')::numeric, 0)))
                   end) as pn,
               coalesce((p.data ->> 'mtMPrezzoSecco')::numeric, 0) as mtm,
               nullif(i.description, i.isin)::varchar(255)                               as description,
               i.residual_life as residual_life,
               coalesce((p.calc ->> 'rateiECedole')::numeric, 0) as ytdMarginInterestAccrual,
               coalesce((p.data ->> 'aggioDisaggio')::numeric, 0) as aggioDisaggio,
               coalesce((p.calc ->> 'costoAmmortizzato')::numeric, 0) as costoAmmortizzato,
               coalesce((p.data ->> 'reserveOci')::numeric, 0) as finalReserve,
               coalesce((p.data ->> 'currentYield')::numeric, 0) * coalesce(p.quantity::numeric, 0) as current_yield,
               coalesce((i.data ->> 'cmVigil')::numeric, 0) as cmVigil
        from position p
                 join instrument i
                      on p.instrument_key = i.instrument_key and p.rpt_date = i.rpt_date
        where p.position_type = 'BOND'
          and p.rpt_date=in_rpt_date
          and p.portfolio_key = in_portfolio_key
        union
        select p.risk_pos_key,
                            p.position_type,
                            p.position_key,
                            p.rpt_date,
                            p.abi,
                            p.book,
                            p.calc,
                            p.created_on,
                            'EUR'                                                               as currency,
                            p.data,
                            p.desk,
                            p.instrument_key,
                            p.isin,
                            p.portfolio_key,
                            coalesce(p.quantity, 0) * coalesce((p.data ->> 'avgPrice')::numeric, 0) as quantity,
                            (p.data ->> 'ytdrealizedPL')::float                                   as realizedpl,
                            p.unrealizedpl,
                            p.exchange,
                            p.parent_position_key,
                            p.parent_rpt_date,
                            coalesce((p.data ->> 'mktPrice')::numeric, 0) * coalesce(p.quantity, 0) as pn,
                            coalesce((p.data ->> 'mktPrice')::numeric, 0) * coalesce(p.quantity, 0) as mtm,
                            p.isin::varchar(255)                                                                as description, 
                            null as residual_life,
                            0 as ytdMarginInterestAccrual,
                            0 as aggioDisaggio,
                            0 as costoAmmortizzato,
                            0 as finalReserve,
                            0 as current_yield,
               null as cmVigil
                     from position p
                     where p.position_type = 'EQUITY'
                       and p.rpt_date=in_rpt_date
                       and p.portfolio_key = in_portfolio_key
        union
                     select p.risk_pos_key,
                            p.position_type,
                            left((MAX(ARRAY[p.position_key]))[1],
                                 length((MAX(ARRAY [p.position_key]))[1]) - 4) as position_key,
                            p.rpt_date,
                            p.abi,
                            p.book,
                            (json_build_object('type', (MAX(ARRAY[p.calc ->> 'type']))[1], 'legs',
                                              (json_strip_nulls(json_agg(json_build_object(
                                                       'costoAmmortizzato', p.calc ->> 'costoAmmortizzato',
                                                       'legId', p.data ->> 'legId', 'eir',
                                                       p.calc ->>
                                                       'eir'))))))::jsonb                  as calc, (MAX(ARRAY[p.created_on]))
                               [1] as created_on,
                            'EUR' as currency,
                            (json_build_object('type', (MAX(ARRAY [p.data ->> 'type']))[1], 'legs',
                                               (json_strip_nulls(json_agg(p.data - 'type')))))::jsonb as data,
                            p.desk,
                            p.instrument_key,
                            p.isin,
                            p.portfolio_key,
                            ABS((MAX(ARRAY [p.quantity]) filter (where p.data ->> 'legId' = 'P'))[1]) as quantity,
                            sum(p.realizedpl) as realizedpl,
                            sum(p.unrealizedpl) as unrealizedpl,
                            p.exchange,
                            (MAX(ARRAY [p.parent_position_key]))[1] as parent_position_key,
                            (MAX(ARRAY [p.parent_rpt_date]))[1] as parent_rpt_date,
                            sum((p.data ->> 'remMktVal'):: numeric + (p.data ->> 'remAccrInt'):: numeric) as pn,
                            sum((p.data ->> 'remMktVal'):: numeric + (p.data ->> 'remAccrInt'):: numeric) as mtm,
                            p.isin:: varchar (255) as description,
                            null as residual_life,
                            sum(coalesce((p.data ->> 'intAccrYTD')::numeric, 0)) as ytdMarginInterestAccrual,
                            0 as aggioDisaggio,
                            sum(coalesce((p.calc ->> 'costoAmmortizzato')::numeric, 0)) as costoAmmortizzato,
                            0 as finalReserve,
                            (case
                                 when
                                         ABS((MAX(ARRAY [p.quantity]) filter (where p.data ->> 'legId' = 'P'))[1]) > 0
                                     then sum(
                                                      coalesce((p.data ->> 'currentYield')::numeric, 0) *
                                                      coalesce((p.data ->> 'remAccrInt')::numeric, 0)
                                              )
                                     / ABS((MAX(ARRAY [p.quantity]) filter (where p.data ->> 'legId' = 'P'))[1])
                                 else 0
                                end)  as current_yield,
                            null as cmVigil
                     from position p
                     where p.position_type = 'SWAP'
                       and p.rpt_date=in_rpt_date
                       and p.portfolio_key  = in_portfolio_key
                     group by p.risk_pos_key, p.position_type, p.rpt_date, p.abi, p.book, p.desk, p.instrument_key, p.isin,
                              p.portfolio_key, p.exchange;
END;
$$;


ALTER FUNCTION public.fun_view_position(in_rpt_date date, in_portfolio_key character varying) OWNER TO exa_db;

--
-- Name: get_daily_pn(date, date, character varying); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.get_daily_pn(v_init_date date, v_end_date date, portfolio_key_src character varying) RETURNS TABLE(date date, val numeric, book_from date, book_to date, bps numeric, cap numeric, floor numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
        with temp_all_date as (
            SELECT rpt_date::date as rpt_date
            FROM generate_series(v_init_date, v_end_date::date, '1 day'::INTERVAL) rpt_date
        ), temp_pos as (
            SELECT b.rpt_date, b.book, b.pn, bc.from, bc.to, bc.bps, bc.cap, bc.floor
            FROM book b
                     JOIN ref_book_config bc ON
                        b.abi = bc.abi
                    AND b.book = bc.book
                    AND b.desk = bc.desk
                    AND b.delega = bc.delega
                    and b.rpt_date between bc."from" and bc."to"
            WHERE b.rpt_date between v_init_date and v_end_date
              AND b.portfolio_key = portfolio_key_src
              AND b.position_type != 'SWAP'
              AND b.pn IS NOT NULL
        )
        select
            t.rpt_date as date,
            sum(p.pn) as val,
            p.from as book_from,
            p.to as book_to,
            p.bps,
            p.cap,
            p.floor
        from temp_all_date t
                 left join temp_pos p on p.rpt_date = t.rpt_date
        group by t.rpt_date, p.from, p.to, p.bps, p.cap, p.floor
        order by t.rpt_date;
END;
$$;


ALTER FUNCTION public.get_daily_pn(v_init_date date, v_end_date date, portfolio_key_src character varying) OWNER TO exa_db;

--
-- Name: get_position_bond_predeal(date, character varying, integer); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.get_position_bond_predeal(rpt_date_src date, portfolio_key_src character varying, predeal_id integer) RETURNS TABLE(position_type character varying, position_key character varying, rpt_date date, abi character varying, book character varying, calc jsonb, created_on timestamp without time zone, currency character varying, data jsonb, desk character varying, instrument_key character varying, isin character varying, portfolio_key character varying, quantity numeric, realizedpl numeric, unrealizedpl numeric, exchange character varying, parent_position_key character varying, parent_rpt_date date, risk_pos_key character varying, pn numeric, mtm numeric, ytd_margin_interest_accrual numeric, aggiodisaggio numeric, costoammortizzato numeric, finalreserve numeric, initialreserve numeric, current_yield numeric, current_yield_weight numeric, cm_vigil numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    select 
    	'BOND_PREDEAL'::varchar as position_type,
	CONCAT_WS('_',pp.predeal_key,pp.position_key)::varchar as position_key,
	rpt_date_src::date as rpt_date,
	pp.abi,
	pp.book,
	coalesce(p.calc, '{}') || jsonb_build_object('type', 'PositionCalcBond','wacClean',pp.price) as calc,
	p.created_on,
	pp.currency,
	p.data,
	pp.desk,
	pp.instrument_key,
	pp.isin,
	pp.portfolio_key,
	pp.quantity * pp.sign as quantity,
	0.0 as realizedpl,
	0.0 as unrealizedpl,
	pp.exchange,
	pp.position_key as parent_position_key,
	rpt_date_src::date as parent_rpt_date,
	p.risk_pos_key,
	0.0 as pn,
	0.0 as mtm,
	0.0 as ytd_margin_interest_accrual,
	0.0 as aggiodisaggio,
	0.0 as costoammortizzato,
	0.0 as finalreserve,
	0.0 as initialreserve,
	0.0 as current_yield,
	0.0 as current_yield_weight,
	0.0 as cm_vigil
	from position_predeal pp 
    left join position p on pp.position_key = p.position_key
    and p.position_type='BOND' and p.rpt_date = rpt_date_src::date
	join predeal pd on pd.id = pp.predeal_key and pd.rpt_date = (select max(pd2.rpt_date) from predeal pd2 where pd2.id=pp.predeal_key)
	join instrument i on pp.instrument_key = i.instrument_key and i.rpt_date = rpt_date_src::date
	where pp.portfolio_key = portfolio_key_src
	and (i.calc ->> 'terminationDate')::date > rpt_date_src::date
	and pp.predeal_key = predeal_id;

END;
$$;


ALTER FUNCTION public.get_position_bond_predeal(rpt_date_src date, portfolio_key_src character varying, predeal_id integer) OWNER TO exa_db;

--
-- Name: get_view_position_predeal(date, character varying, integer); Type: FUNCTION; Schema: public; Owner: exa_db
--

CREATE FUNCTION public.get_view_position_predeal(rpt_date_src date, portfolio_key_src character varying, predeal_id integer) RETURNS TABLE(position_key character varying, instrument_key character varying, portfolio_key character varying, book character varying, abi character varying, desk character varying, currency character varying, quantity numeric, quantity_predeal numeric, price numeric, price_predeal numeric, sign integer, predeal boolean, position_type character varying, rpt_date date)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
        select
            p.position_key,
            p.instrument_key,
            p.portfolio_key,
            p.book,
            p.abi,
            p.desk,
            p.currency,
            p.quantity,
            pp.quantity as quantity_predeal,
            coalesce(tp.price, cast(pi.data ->> 'priceEOD' as numeric)) as price,
            pp.price as price_predeal,
            coalesce(pp.sign, 1) as sign,
            case
                when pp.position_key is NULL then false
                else true
                end as predeal,
            p.position_type,
            p.rpt_date
        from position p
                 left join position_predeal pp on p.position_key = pp.position_key and pp.predeal_key=predeal_id
                 left join instrument pi on pi.instrument_key = p.instrument_key and pi.rpt_date=rpt_date_src
                 left join price tp on pi.price_key = tp.price_key
        where p.position_type = 'BOND'
          and p.rpt_date = rpt_date_src
          and p.portfolio_key = portfolio_key_src
          and cast(pi.calc ->> 'terminationDate' as date) > rpt_date_src
        UNION ALL

        select
            pp.position_key,
            pp.instrument_key,
            pp.portfolio_key,
            pp.book,
            pp.abi,
            pp.desk,
            pp.currency,
            0                 as quantity,
            pp.quantity       as quantity_predeal,
            0                 as price,
            pp.price          as price_predeal,
            pp.sign           as sign,
            true              as predeal,
            'BOND'            as position_type,
            cast(rpt_date_src as date)
        from position_predeal pp
                 left join instrument pi on pi.instrument_key = pp.instrument_key and pi.rpt_date=rpt_date_src
        where not exists (
                select * from position p
                where p.position_key = pp.position_key
                  AND p.rpt_date = rpt_date_src
                  and p.portfolio_key = portfolio_key_src
            )
          AND pp.portfolio_key = portfolio_key_src
          and pp.predeal_key = predeal_id
          and cast(pi.calc ->> 'terminationDate' as date) > rpt_date_src;



END;
$$;


ALTER FUNCTION public.get_view_position_predeal(rpt_date_src date, portfolio_key_src character varying, predeal_id integer) OWNER TO exa_db;

--
-- Name: p_apm_file_log_extract_insert(character varying, character varying, character varying, date, character varying, character varying, character varying); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_apm_file_log_extract_insert(in_file_key character varying, source_archive_uri character varying, in_file_name character varying, in_file_rpt_date date, in_file_modified_on character varying, in_file_created_on character varying, in_location_name character varying)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_parent_import_id bigint;
    v_import_id integer;
    v_rpt_date date;
    v_file_key varchar;
    v_state_id integer = 0;

BEGIN
    -- fileKey must be in upper case
    select upper(in_file_key) into v_file_key;

    -- detail related to source archive_uri
    v_parent_import_id := (
        select import_id
        from apm_file_log
        where archive_uri = source_archive_uri
    );

    if (v_parent_import_id is NULL) THEN
        raise exception 'Invalid source_archive_uri "%"', source_archive_uri;
    end if;

    v_rpt_date := (
        select rpt_date
        from apm_file_log
        where import_id = v_parent_import_id
    );

    -- Check if file_key already exists
    select import_id
    into v_import_id
    from apm_file_log
    where parent_import_id = v_parent_import_id
      and file_key = v_file_key;

    IF v_import_id is null THEN
        insert into apm_file_log(
            rpt_date, file_key, parent_import_id,
            is_import, retry_count, state_id,
            content
        )
        values (
                   v_rpt_date, v_file_key, v_parent_import_id,
                   false, 0, v_state_id,
                   json_build_object(
                           'file_name', in_file_name,
                           'source_file', source_archive_uri,
                           'location_name', in_location_name,
                           'file_rpt_date', to_char(in_file_rpt_date, 'YYYY-MM-DD'),
                           'file_modified_on', in_file_modified_on,
                           'file_created_on', in_file_created_on
                       )
               );
    ELSE
        /**
          NOTE: in the update, content are not updated.
         */
        update apm_file_log
        set
            rpt_date = v_rpt_date,
            file_key = v_file_key,
            retry_count = apm_file_log.retry_count + 1,
            state_id = v_state_id,
            modified_on = now()
        where import_id = v_import_id;
    END IF;

END
$$;


ALTER PROCEDURE public.p_apm_file_log_extract_insert(in_file_key character varying, source_archive_uri character varying, in_file_name character varying, in_file_rpt_date date, in_file_modified_on character varying, in_file_created_on character varying, in_location_name character varying) OWNER TO exa_db;

--
-- Name: p_apm_file_log_import_upsert(date, character varying, character varying, character varying, date, character varying, character varying, character varying); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_apm_file_log_import_upsert(in_rpt_date date, in_file_key character varying, in_archive_uri character varying, in_file_name character varying, in_file_rpt_date date, in_file_modified_on character varying, in_file_created_on character varying, in_state character varying)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_file_key varchar;
    v_import_id integer;
    v_state_id integer;

BEGIN
    -- fileKey must be in upper case
    select upper(in_file_key) into v_file_key;

    -- fileKey must be in upper case
    v_state_id := (
        select state_id
        from ref_state where state = in_state
    );

    if (v_state_id is NULL) THEN
        raise exception 'Invalid state "%"', in_state;
    end if;

    -- make sure that file_key
    IF not exists(select * from import_file where file_key = v_file_key) THEN
        insert into import_file(file_key, gsuri, json)
        values(v_file_key, v_file_key, '{}'::jsonb);
    end if;

    -- Check if import already exists
    select import_id
    into v_import_id
    from apm_file_log
    where archive_uri = in_archive_uri;

    IF v_import_id is null THEN
        insert into apm_file_log(
            rpt_date, file_key, archive_uri,
            is_import, retry_count, state_id,
            content
        )
        values (
                   in_rpt_date, v_file_key, in_archive_uri,
                   true, 0, v_state_id,
                   json_build_object(
                           'file_name', in_file_name,
                           'file_rpt_date', to_char(in_file_rpt_date, 'YYYY-MM-DD'),
                           'file_modified_on', in_file_modified_on,
                           'file_created_on', in_file_created_on
                       )
               );
    ELSE
        /**
          NOTE: in the update, in_file_name and in_file_rpt_date are not updated.
         */
        update apm_file_log
        set
            rpt_date = in_rpt_date,
            file_key = v_file_key,
            archive_uri = in_archive_uri,
            retry_count = apm_file_log.retry_count + 1,
            state_id = v_state_id,
            modified_on = now()
        where import_id = v_import_id;
    END IF;
END
$$;


ALTER PROCEDURE public.p_apm_file_log_import_upsert(in_rpt_date date, in_file_key character varying, in_archive_uri character varying, in_file_name character varying, in_file_rpt_date date, in_file_modified_on character varying, in_file_created_on character varying, in_state character varying) OWNER TO exa_db;

--
-- Name: p_apm_file_monitor_status_process(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_apm_file_monitor_status_process(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Check the files without location
    update apm_file_log
    set monitor_status = 'OK'
    where rpt_date = in_rpt_date
      and monitor_status is NULL
      and file_key in (
        select ts.file_key
        from ref_apm_file_key ts
        where ts.active_flag = true
          and ts.monitor_flag = true
          and ts.location_name_flag = false
    );

    -- Check the files with location - OK
    update apm_file_log
    set monitor_status = 'OK'
    where rpt_date = in_rpt_date
      and monitor_status is NULL
      and exists (
            select *
            from mview_file_loc v
            where v.file_key = apm_file_log.file_key
              and v.location_name = (apm_file_log.content ->> 'location_name')
        );

    -- Check the files with location - EXTRA
    update apm_file_log
    set monitor_status = 'EXTRA'
    where rpt_date = in_rpt_date
      and monitor_status is NULL
      and file_key in (
        select ts.file_key
        from ref_apm_file_key ts
        where ts.active_flag = true
          and ts.monitor_flag = true
    );

    -- Add missing files
    insert into apm_file_log(
        rpt_date, file_key, retry_count, is_import, state_id, monitor_status, content
    )
    select
        in_rpt_date as rpt_date,
        v.file_key,
        0 as retry_count,
        false as is_import,
        0 as state_id,
        'MISSING' as monitor_status,
        json_build_object(
                'location_name', v.location_name,
                'file_name', v.file_key_desc || '_' || v.location_name || '.xml'
            ) as content
    from mview_file_loc v
    where not exists (
            select * from apm_file_log ts
            where ts.rpt_date = in_rpt_date
              and ts.file_key = v.file_key
              and (ts.content ->> 'location_name') = v.location_name
        );


END
$$;


ALTER PROCEDURE public.p_apm_file_monitor_status_process(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_apm_file_rec_delete(character varying, character varying); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_apm_file_rec_delete(in_rec_source_ref character varying, in_file_name character varying)
    LANGUAGE plpgsql
    AS $$

BEGIN
    IF (in_file_name is NULL) THEN
        delete from apm_import_rec
        where rec_source_ref = in_rec_source_ref;
    ELSE
        delete from apm_import_rec
        where rec_source_ref = in_rec_source_ref
          and file_name = in_file_name;
    END IF;
END
$$;


ALTER PROCEDURE public.p_apm_file_rec_delete(in_rec_source_ref character varying, in_file_name character varying) OWNER TO exa_db;

--
-- Name: p_apm_file_rec_process(character varying, date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_apm_file_rec_process(in_rec_source_ref character varying, in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Tag the unknown files
    update apm_import_rec
    set monitor_status = 'EXTRA'
    where rec_source_ref = in_rec_source_ref
      and monitor_status is NULL
      and file_key like 'UNKNOWN%';

    -- Ignore inactive or files that shouldn't be monitored
    update apm_import_rec
    set monitor_status = 'IGNORE'
    where rec_source_ref = in_rec_source_ref
      and monitor_status is NULL
      and file_key in (
        select ts.file_key
        from ref_apm_file_key ts
        where ts.active_flag = false OR ts.monitor_flag = false
    );

    -- Check the files without location
    update apm_import_rec
    set monitor_status = 'OK'
    where rec_source_ref = in_rec_source_ref
      and monitor_status is NULL
      and file_key in (
        select ts.file_key
        from ref_apm_file_key ts
        where ts.active_flag = true
          and ts.monitor_flag = true
          and ts.location_name_flag = false
    );

    -- Check the files with location - OK
    update apm_import_rec
    set monitor_status = 'OK'
    where rec_source_ref = in_rec_source_ref
      and monitor_status is NULL
      and exists (
            select *
            from mview_file_loc v
            where v.file_key = apm_import_rec.file_key
              and v.location_name = (apm_import_rec.content ->> 'location_name')
        );

    -- Add missing files with location
    insert into apm_import_rec(
        rec_source_ref, file_name, source,
        rpt_date, file_key,
        monitor_status, retry_count, content
    )
    select
        in_rec_source_ref,
        v.file_key_desc || '_' || v.location_name || '.xml' as file_name,
        'processing' as source,

        in_rpt_date as rpt_date,
        v.file_key,

        'MISSING' as monitor_status,
        0 as retry_count,
        json_build_object(
                'file_rpt_date', to_char(in_rpt_date, 'YYYY-MM-DD'),
                'location_name', v.location_name
            ) as content
    from mview_file_loc v
    where not exists (
            select * from apm_import_rec ts
            where ts.rec_source_ref = in_rec_source_ref
              and ts.file_key = v.file_key
              and (ts.content ->> 'location_name') = v.location_name
        );

    -- Add missing files without location
    insert into apm_import_rec(
        rec_source_ref, file_name, source,
        rpt_date, file_key,
        monitor_status, retry_count, content
    )
    select
        in_rec_source_ref,
        v.file_key_desc as file_name,
        v.source,

        in_rpt_date as rpt_date,
        v.file_key,

        'MISSING' as monitor_status,
        0 as retry_count,
        json_build_object(
                'file_rpt_date', to_char(in_rpt_date, 'YYYY-MM-DD')
            ) as content
    from ref_apm_file_key v
    where v.active_flag = true
      and v.monitor_flag = true
      and v.location_name_flag = false
      and not exists (
            select * from apm_import_rec ts
            where ts.rec_source_ref = in_rec_source_ref
              and ts.file_key = v.file_key
        );

    -- Everything else left in the rec table should be considered EXTRA
    update apm_import_rec
    set monitor_status = 'EXTRA'
    where rec_source_ref = in_rec_source_ref
      and monitor_status is NULL;
END
$$;


ALTER PROCEDURE public.p_apm_file_rec_process(in_rec_source_ref character varying, in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_apm_file_rec_upsert(character varying, character varying, character varying, date, character varying, date, character varying, character varying, character varying); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_apm_file_rec_upsert(in_rec_source_ref character varying, in_file_name character varying, in_source character varying, in_rpt_date date, in_file_key character varying, in_file_rpt_date date, in_location_name character varying, in_file_modified_on character varying, in_file_created_on character varying)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_file_key varchar;
    v_import_rec_id integer;

BEGIN
    -- fileKey must be in upper case
    select upper(in_file_key) into v_file_key;

    -- Check if import already exists
    select import_rec_id into v_import_rec_id
    from apm_import_rec
    where rec_source_ref = in_rec_source_ref
      and file_name = in_file_name;

    -- Deal with unknown filekey
    IF not exists (select * from ref_apm_file_key where file_key = v_file_key) THEN
        IF (in_source = 'cumulative') THEN
            select 'UNKNOWN.CUMULATIVE' into v_file_key;
        ELSE
            select 'UNKNOWN.PROCESSING' into v_file_key;
        END IF;
    END IF;

    -- Set is import
    IF v_import_rec_id is null THEN
        -- Create a new row
        insert into apm_import_rec(
            rec_source_ref, file_name,
            source, rpt_date, file_key, retry_count,
            content
        )
        values (
                   in_rec_source_ref, in_file_name,
                   in_source, in_rpt_date, v_file_key, 0,
                   json_build_object(
                           'file_rpt_date', to_char(in_file_rpt_date, 'YYYY-MM-DD'),
                           'location_name', in_location_name,
                           'file_modified_on', in_file_modified_on,
                           'file_created_on', in_file_created_on
                       )
               );
    ELSE
        -- Update existing row using the unique key
        update apm_import_rec
        set
            source = in_source,
            rpt_date = in_rpt_date,
            file_key = v_file_key,
            retry_count = apm_import_rec.retry_count + 1,
            content = json_build_object(
                    'file_rpt_date', to_char(in_file_rpt_date, 'YYYY-MM-DD'),
                    'location_name', in_location_name,
                    'file_modified_on', in_file_modified_on,
                    'file_created_on', in_file_created_on
                ),
            modified_on = now()
        where import_rec_id = v_import_rec_id;
    END IF;
END
$$;


ALTER PROCEDURE public.p_apm_file_rec_upsert(in_rec_source_ref character varying, in_file_name character varying, in_source character varying, in_rpt_date date, in_file_key character varying, in_file_rpt_date date, in_location_name character varying, in_file_modified_on character varying, in_file_created_on character varying) OWNER TO exa_db;

--
-- Name: p_clean_up_xo30_import(); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_clean_up_xo30_import()
    LANGUAGE plpgsql
    AS $$
	BEGIN
		truncate table import.position;
		truncate table import.instrument cascade;
		truncate table import.limit_value;
		truncate table import.risk_market_data;
		truncate table import.risk_pos;
		truncate table import.risk_ptf;
	END;
$$;


ALTER PROCEDURE public.p_clean_up_xo30_import() OWNER TO exa_db;

--
-- Name: p_copy_missing_instruments(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_copy_missing_instruments(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_prev_rpt_date date;

BEGIN
    v_prev_rpt_date = (
        select max(rpt_date)
        from ref_rpt_date
        where rpt_date < in_rpt_date
          and state_id in (40000, 80000)
    );

    insert into import.instrument(
        rpt_date, instrument_type, instrument_key, asset_class_key, country, currency, description, isin,
        issuer_key, p_amt_out, p_duration, p_iscoring, p_lotto_minimo, p_price, p_residual_life, p_ytm,
        price_key, rating_key, ratings, sub_type, type, calc, data, duration, exchange, residual_life, ytm, ticker,
        created_on
    )
    select
        in_rpt_date, i.instrument_type, i.instrument_key, i.asset_class_key, i.country,  i.currency, i.description, i.isin,
        i.issuer_key, i.p_amt_out, 0, i.p_iscoring, i.p_lotto_minimo, i.p_price, i.p_residual_life, 0,
        i.price_key, i.rating_key, i.ratings, i.sub_type, i.type, i.calc, i.data, 0, i.exchange, i.residual_life, 0, i.ticker,
        now()
    from public.instrument i
    where i.rpt_date = v_prev_rpt_date
      and i.instrument_type != 'SWAP'
      and not exists (
            select * from import.instrument c
            where c.instrument_key = i.instrument_key
              and c.rpt_date = in_rpt_date
              and c.instrument_type != 'SWAP'
        );

END
$$;


ALTER PROCEDURE public.p_copy_missing_instruments(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_data_cleanup(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_data_cleanup(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_rn_rating int;

BEGIN
    v_rn_rating = (
        select rating_key
        from ref_rating
        where classe_merito = 'NR'
    );

    -- Ensure that bond ratings are never null
    update instrument
    set rating_key = v_rn_rating
    where rpt_date = in_rpt_date
      and rating_key IS NULL
      and instrument_type not in ('SWAP', 'EQUITY');

    -- HACK: fix the fact that limit_value are always imported as 1900-01-01
    update limit_value
    set rpt_date = in_rpt_date
    where rpt_date = '1900-01-01';

    -- HACK: fix the fixing > 100
    UPDATE risk_market_data_fixing
    SET rate = rate / 100
    WHERE date >= '2022-08-31'
      AND risk_market_data_fixing_key in (
                                          'HICPXT_EUR_1Y',
                                          'HICPxT_EUR_1Y',
                                          'ITCPI_EUR_1Y'
        ) AND rate > 20;

END
$$;


ALTER PROCEDURE public.p_data_cleanup(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_delete_rpt_date(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_delete_rpt_date(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
	begin
		update ref_rpt_date
		set state_id = 0
		where rpt_date = in_rpt_date;
	
		delete from public.position
		where rpt_date = in_rpt_date;
	
		delete from public.instrument
		where rpt_date = in_rpt_date;
	
		delete from public.limit_value
		where rpt_date = in_rpt_date;
	
		delete from public.risk_market_data
		where rpt_date = in_rpt_date;
	
		delete from public.risk_pos
		where rpt_date = in_rpt_date;
	
		delete from public.risk_ptf
		where rpt_date = in_rpt_date;
		
	END;
$$;


ALTER PROCEDURE public.p_delete_rpt_date(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_hbe_position_upsert(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_hbe_position_upsert(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_now timestamptz;
    v_default_ends_on timestamptz;

BEGIN

    select current_timestamp into v_now;
    select cast('3000-01-01T00:00:00.000000Z' AS timestamptz) into v_default_ends_on;

    -- Start with deleted rows.  Make a copy of the row to indicate that is has been deleted
    update hbe_position
    set ends_on = v_now
    where ends_on = v_default_ends_on
    and not exists(
        select * from view_position_limited_isin v
        where v.position_key = hbe_position.position_key
          and v.rpt_date = in_rpt_date
    );

    insert into hbe_position(
        position_key,
        abi, book, desk, isin,
        currency, quantity, realizedpl,
        data, row_hash,
        starts_on, ends_on, deleted
    )
    select
        t.position_key,
        t.abi,
        t.book,
        t.desk,
        t.isin,
        t.currency,
        t.quantity,
        t.realizedpl,
        t.data,
        t.row_hash,
        v_now as starts_on,
        v_default_ends_on as ends_on,
        true as deleted
    from hbe_position t
    where t.ends_on = v_now;
    /*
      not exists(
        select * from view_position_limited_isin ts
        where ts.position_key = t.position_key
          and ts.rpt_date = in_rpt_date
    );
     */

    -- Insert modified rows
    update hbe_position
    set ends_on = v_now
    from view_position_limited_isin v
    where v.position_key = hbe_position.position_key
      and v.rpt_date = in_rpt_date
      and hbe_position.ends_on = v_default_ends_on
      and v.row_hash != hbe_position.row_hash
    ;

    insert into hbe_position(
        position_key,
        abi, book, desk, isin,
        currency, quantity, realizedpl,
        data, row_hash,
        starts_on, ends_on, deleted
    )
    select
        t.position_key,
        t.abi,
        t.book,
        t.desk,
        t.isin,
        t.currency,
        t.quantity,
        t.realizedpl,
        t.data,
        t.row_hash,
        v_now as starts_on,
        v_default_ends_on as ends_on,
        false as deleted
    from view_position_limited_isin t
    join hbe_position hb on (hb.position_key = t.position_key and hb.ends_on = v_now)
    where t.rpt_date = in_rpt_date
      and t.row_hash != hb.row_hash
    ;

    -- Add new rows
    insert into hbe_position(
        position_key,
        abi, book, desk, isin,
        currency, quantity, realizedpl,
        data, row_hash,
        starts_on, ends_on, deleted
    )
    select
        t.position_key,
        t.abi,
        t.book,
        t.desk,
        t.isin,
        t.currency,
        t.quantity,
        t.realizedpl,
        t.data,
        t.row_hash,
        v_now as starts_on,
        v_default_ends_on as ends_on,
        false as deleted
    from view_position_limited_isin t
    where t.rpt_date = in_rpt_date
    and not exists (
        select *
        from hbe_position ts
        where ts.position_key = t.position_key
    );

    -- Create rpt records
    insert into rpt_position(
        rpt_date,
        position_key,
        starts_on
    )
    select
        in_rpt_date,
        position_key,
        starts_on
    from hbe_position
    where ends_on = v_default_ends_on;

END
$$;


ALTER PROCEDURE public.p_hbe_position_upsert(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_import_log_upsert(date, character varying, character varying, character varying, character varying); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_import_log_upsert(in_rpt_date date, in_file_key character varying, in_archive_uri character varying, in_file_name character varying, in_state character varying)
    LANGUAGE plpgsql
    AS $$

DECLARE
    v_file_key varchar;
    v_import_id integer;
    v_state_id integer;

BEGIN
    -- fileKey must be in upper case
    select upper(in_file_key) into v_file_key;

    -- fileKey must be in upper case
    v_state_id := (
        select state_id
        from ref_state where state = in_state
    );

    if (v_state_id is NULL) THEN
        raise exception 'Invalid state "%"', in_state;
    end if;

    -- make sure that file_key
    IF not exists(select * from import_file where file_key = v_file_key) THEN
        insert into import_file(file_key, gsuri, json)
        values(v_file_key, v_file_key, '{}'::jsonb);
    end if;

    -- Check if import already exists
    select import_id into v_import_id
    from import_log where archive_uri = in_archive_uri;

    IF v_import_id is null THEN
        insert into import_log(
            rpt_date, file_key, archive_uri,
            file_name, retry_count, state_id
        )
        values (
                   in_rpt_date, v_file_key, in_archive_uri,
                   in_file_name, 0, v_state_id
               );
    ELSE
        -- TODO: must not allow override of file_key
        update import_log
        set
            rpt_date = in_rpt_date,
            file_key = v_file_key,
            archive_uri = in_archive_uri,
            file_name = in_file_name,
            retry_count = import_log.retry_count + 1,
            state_id = v_state_id,
            modifield_on = now()
        where import_id = v_import_id;
    END IF;
END
$$;


ALTER PROCEDURE public.p_import_log_upsert(in_rpt_date date, in_file_key character varying, in_archive_uri character varying, in_file_name character varying, in_state character varying) OWNER TO exa_db;

--
-- Name: p_insert_limit_value(date, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, character varying, boolean, character varying, numeric); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_insert_limit_value(in_rpt_date date, in_limit_value_key character varying, in_limit_key character varying, in_limit_display character varying, in_abi character varying, in_ia_id character varying, in_ia_name character varying, in_ia_description character varying, in_ic_id character varying, in_ic_description character varying, in_l1max numeric, in_l1max_perc numeric, in_l1min numeric, in_l1min_perc numeric, in_l2max numeric, in_l2max_perc numeric, in_l2min numeric, in_l2min_perc numeric, in_max numeric, in_max_perc numeric, in_min numeric, in_min_perc numeric, in_rl_limit_name character varying, in_rp_exceed boolean, in_rp_in_limits character varying, in_rp_value numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    insert into BCP_LIMIT_VALUE(
        rpt_date, limit_value_key,
        limit_key, limit_display, abi,
        ia_id, ia_name, ia_description, ic_id, ic_description,
        l1max, l1max_perc, l1min, l1min_perc,
        l2max, l2max_perc, l2min, l2min_perc,
        max, max_perc, min, min_perc,
        rl_limit_name, rp_exceed, rp_in_limits, rp_value,
        created_on
    )
    VALUES (
               in_rpt_date, in_limit_value_key,
               in_limit_key, in_limit_display, in_abi,
               in_ia_id, in_ia_name, in_ia_description, in_ic_id, in_ic_description,
               in_l1max, in_l1max_perc, in_l1min, in_l1min_perc,
               in_l2max, in_l2max_perc, in_l2min, in_l2min_perc,
               in_max, in_max_perc, in_min, in_min_perc,
               in_rl_limit_name, in_rp_exceed, in_rp_in_limits, in_rp_value,
               now()
           );
END
$$;


ALTER PROCEDURE public.p_insert_limit_value(in_rpt_date date, in_limit_value_key character varying, in_limit_key character varying, in_limit_display character varying, in_abi character varying, in_ia_id character varying, in_ia_name character varying, in_ia_description character varying, in_ic_id character varying, in_ic_description character varying, in_l1max numeric, in_l1max_perc numeric, in_l1min numeric, in_l1min_perc numeric, in_l2max numeric, in_l2max_perc numeric, in_l2min numeric, in_l2min_perc numeric, in_max numeric, in_max_perc numeric, in_min numeric, in_min_perc numeric, in_rl_limit_name character varying, in_rp_exceed boolean, in_rp_in_limits character varying, in_rp_value numeric) OWNER TO exa_db;

--
-- Name: p_limit_value_pre_sync(); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_limit_value_pre_sync()
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin

	
update import.limit_value lv
set
	rp_value = m.importo::numeric
from import.m50 m
where
	lv.ia_name = 'LMT 02'
	and lv.abi = m.abi;




end
$$;


ALTER PROCEDURE public.p_limit_value_pre_sync() OWNER TO exa_db;

--
-- Name: p_position_pre_sync(); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_position_pre_sync()
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin

	
-- Start with exclusion
update
	import.position as p
set
	include = false
from
	import.ref_position_filter r
where
	p.desk = r.desk
	and r.abi = '*'
	and r.to_include = false;

update
	import.position as p
set
	include = false
from
	import.ref_position_filter r
where
	p.desk = r.desk
	and p.abi = r.abi
	and r.to_include = false;

-- Next inclusion
update
	import.position as p
set
 include = true
from
	import.ref_position_filter r
where
    p.desk = r.desk
    and r.abi = '*'
    and r.to_include = true;

   
update
	import.position as p
set
 include = true
from
	import.ref_position_filter r
where
    p.desk = r.desk
    and p.abi = r.abi  
    and r.to_include = true;



end
$$;


ALTER PROCEDURE public.p_position_pre_sync() OWNER TO exa_db;

--
-- Name: p_set_rpt_date(character varying, date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_set_rpt_date(in_to_state character varying, in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
BEGIN
    call p_set_rpt_date(
            in_to_state, in_rpt_date,
            null, null, true
        );
END
$$;


ALTER PROCEDURE public.p_set_rpt_date(in_to_state character varying, in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_set_rpt_date(character varying, date, date, date, boolean); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_set_rpt_date(in_to_state character varying, in_rpt_date date, in_prev_business_date date, in_next_business_date date, in_business_day boolean)
    LANGUAGE plpgsql
    AS $$

/**

Primary logic for rpt_date processing:

## First morning run
1. `store-to-processing` workflow sets rpt_date with state of `active`
2. As this is a new rpt_date, the proc will change the state to `processing`
3. `xo30-import` is called and after `syncToPublic` step,
 sets rpt_date with state of `done` (from `processing`)
4. `done_on` date updated

## Intra-day run
1. `store-to-processing` workflow sets rpt_date with state of `active`
2. rpt_date state is set to `active`
3. `xo30-import` is called and after `syncToPublic` step,
 sets rpt_date with state of `done` (from `active`)
4. `done_on` date updated

## Note
* If in_to_state is `active` but rpt_date doesn't exists, in_to_state is changed to `processing`
* If in_to_state is `active` and current state in db is `processing`, in_to_state is changed to `processing`

 */

DECLARE
    v_to_state_id int;
    v_curr_state varchar;
    v_curr_state_id int;
    v_other_rpt_date date;
    v_processing_state_id int := 10000;
    v_active_state_id int := 40000;
    v_done_state_id int := 80000;

BEGIN
    -- Must make sure that state exists in_state
    v_to_state_id := (
        select state_id
        from ref_state where state = in_to_state
    );

    if (v_to_state_id is NULL) THEN
        raise exception 'Invalid state "%"', in_to_state;
    end if;

    -- Get current state id from the ref_rpt_date table.  If doesn't exists, create rpt_date and set to init
    v_curr_state_id := (
        select state_id
        from ref_rpt_date
        where rpt_date = in_rpt_date
    );

    if v_curr_state_id is null THEN
        v_curr_state_id := 0; -- INIT

        if in_prev_business_date is NULL then
            in_prev_business_date := in_rpt_date;
        end if;

        if in_next_business_date is NULL then
            in_next_business_date := in_rpt_date;
        end if;

        insert into ref_rpt_date(
            rpt_date, display_date, business_day,
            prev_business_date, next_business_date, state_id
        )
        values (
                   in_rpt_date, in_rpt_date, in_business_day,
                   in_prev_business_date, in_next_business_date, v_curr_state_id
               );

        -- if rpt_date doesn't exists and asking to set to active, the system should
        -- really set itself to processing
        if (v_to_state_id = v_active_state_id) then
            v_to_state_id := v_processing_state_id;
        end if;
    end if;

    /*
        As per description, the `processing` state is never explicitly set by workflow but converted
        from `active` to `processing`.  As result, when xo30-import fails and is re-run, there is a
        possibility that db contain the state of `processing` but incoming request is `active`.

        In this case, to_state should be changed from `active` to `processing` as we do not wish to
        transition from `processing` to `active`.
     */
    if (
                v_to_state_id = v_active_state_id
            and (
                            v_curr_state_id = v_processing_state_id
                        or v_curr_state_id = 0
                    )
        ) then
        v_to_state_id := v_processing_state_id;
    end if;


    -- Get current state
    v_curr_state := (
        select state from ref_state
        where state_id = v_curr_state_id
    );

    -- If to and from state is the same, do nothing
    if v_to_state_id = v_curr_state_id then
        return;
    end if;

    -- Validate transition
    if (
        -- Can I go from processing v_curr_state_id to v_to_state_id
        select state_id from ref_state
        where state_id = v_curr_state_id
          and v_to_state_id = ANY(state_transition)
    ) is NULL then
        raise exception 'Cannot transition from "%" to "%"', v_curr_state, in_to_state;
    end if;

    -- Only one processing can exists
    if v_to_state_id = v_processing_state_id then
        v_other_rpt_date := (select max(rpt_date) from ref_rpt_date where state_id = v_processing_state_id);
        if v_other_rpt_date is not NULL then
            raise exception '% rpt_date is already in "processing" state so cannot transition % rpt_date', v_other_rpt_date, in_rpt_date;
        end if;
    end if;

    -- Call post processing if transitioning from "processing" or "active" to "done"
    if (
                v_to_state_id = v_done_state_id
            AND (
                            v_curr_state_id = v_active_state_id
                        OR v_curr_state_id = v_processing_state_id
                    )
        ) then
        call p_update_multiranking_sector(in_rpt_date);
        call p_update_percentile(in_rpt_date);
        call p_update_percentile_price(in_rpt_date);
        call p_data_cleanup(in_rpt_date);
    end if;

    -- Transition rpt_date
    update ref_rpt_date
    set state_id = v_to_state_id,
        modified_on = now()
    where rpt_date = in_rpt_date;

    -- Set done_on if current state is done
    if (v_to_state_id = v_done_state_id) then
        update ref_rpt_date
        set done_on = now()
        where rpt_date = in_rpt_date;
    end if;
END
$$;


ALTER PROCEDURE public.p_set_rpt_date(in_to_state character varying, in_rpt_date date, in_prev_business_date date, in_next_business_date date, in_business_day boolean) OWNER TO exa_db;

--
-- Name: p_sync_all(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_all(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
begin
CALL public.p_sync_Risk_market_data(in_rpt_date);
CALL public.p_sync_Risk_pos(in_rpt_date);
CALL public.p_sync_Risk_ptf(in_rpt_date);
CALL public.p_sync_Limit_value(in_rpt_date);
CALL public.p_sync_Instrument(in_rpt_date);
CALL public.p_sync_Position(in_rpt_date);
end
$$;


ALTER PROCEDURE public.p_sync_all(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_bus_model(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_bus_model(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.bus_model;
IF size = 0 THEN 
RETURN;
END IF;

insert
	into
	public.bus_model
(position_type,
    position_key,
    bus_model,
    rpt_date,
    abi,
    book,
    calc,
    created_on,
    currency,
    data,
    desk,
    instrument_key,
    isin,
    portfolio_key,
    quantity,
    realizedpl,
    unrealizedpl,
    exchange,
    parent_position_key,
    parent_rpt_date,
    risk_pos_key,
    pn,
    mtm,
    ytd_margin_interest_accrual,
    aggiodisaggio,
    costoammortizzato,
    finalreserve,
    current_yield,
    current_yield_weight,
    cm_vigil
)
select
src.position_type,
    src.position_key,
    src.bus_model,
    in_rpt_date as rpt_date,
    src.abi,
    src.book,
    src.calc,
    src.created_on,
    src.currency,
    src.data,
    src.desk,
    src.instrument_key,
    src.isin,
    src.portfolio_key,
    src.quantity,
    src.realizedpl,
    src.unrealizedpl,
    src.exchange,
    src.parent_position_key,
    src.parent_rpt_date,
    src.risk_pos_key,
    src.pn,
    src.mtm,
    src.ytd_margin_interest_accrual,
    src.aggiodisaggio,
    src.costoammortizzato,
    src.finalreserve,
    src.current_yield,
    src.current_yield_weight,
    src.cm_vigil
from import.bus_model src
ON CONFLICT(rpt_date, position_key) DO
UPDATE SET
position_type = excluded.position_type,
    bus_model = excluded.bus_model,
    abi = excluded.abi,
    book = excluded.book,
    calc = excluded.calc,
    created_on = excluded.created_on,
    currency = excluded.currency,
    data = excluded.data,
    desk = excluded.desk,
    instrument_key = excluded.instrument_key,
    isin = excluded.isin,
    portfolio_key = excluded.portfolio_key,
    quantity = excluded.quantity,
    realizedpl = excluded.realizedpl,
    unrealizedpl = excluded.unrealizedpl,
    exchange = excluded.exchange,
    parent_position_key = excluded.parent_position_key,
    parent_rpt_date = excluded.parent_rpt_date,
    risk_pos_key = excluded.risk_pos_key,
    pn = excluded.pn,
    mtm = excluded.mtm,
    ytd_margin_interest_accrual = excluded.ytd_margin_interest_accrual,
    aggiodisaggio = excluded.aggiodisaggio,
    costoammortizzato = excluded.costoammortizzato,
    finalreserve = excluded.finalreserve,
    current_yield = excluded.current_yield,
    current_yield_weight = excluded.current_yield_weight,
    cm_vigil = excluded.cm_vigil;
DELETE FROM public.bus_model
WHERE rpt_date=in_rpt_date and position_key NOT IN (SELECT position_key FROM import.bus_model);

end
$$;


ALTER PROCEDURE public.p_sync_bus_model(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_finance(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_finance(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.finance;
IF size = 0 THEN 
RETURN;
END IF;

insert
	into
	public.finance
(finance_key,
    rpt_date,
    abi,
    modello_di_business,
    sub_modello_di_business,
    isin,
    x5_quantity,
    xm_quantity,
    saldo_summit,
    difference,
    saldo_finance,
    desk,
    book,
    currency,
    status
)
select
src.finance_key,
    in_rpt_date as rpt_date,
    src.abi,
    src.modello_di_business,
    src.sub_modello_di_business,
    src.isin,
    src.x5_quantity,
    src.xm_quantity,
    src.saldo_summit,
    src.difference,
    src.saldo_finance,
    src.desk,
    src.book,
    src.currency,
    src.status
from import.finance src
ON CONFLICT(rpt_date, finance_key) DO
UPDATE SET
abi = excluded.abi,
    modello_di_business = excluded.modello_di_business,
    sub_modello_di_business = excluded.sub_modello_di_business,
    isin = excluded.isin,
    x5_quantity = excluded.x5_quantity,
    xm_quantity = excluded.xm_quantity,
    saldo_summit = excluded.saldo_summit,
    difference = excluded.difference,
    saldo_finance = excluded.saldo_finance,
    desk = excluded.desk,
    book = excluded.book,
    currency = excluded.currency,
    status = excluded.status;
DELETE FROM public.finance
WHERE rpt_date=in_rpt_date and finance_key NOT IN (SELECT finance_key FROM import.finance);

end
$$;


ALTER PROCEDURE public.p_sync_finance(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_gdl(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_gdl(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.gdl;
IF size = 0 THEN 
RETURN;
END IF;

insert
	into
	public.gdl
(rpt_date,
    abi
)
select
in_rpt_date as rpt_date,
    src.abi
from import.gdl src
ON CONFLICT(rpt_date, abi) DO
NOTHING
;
DELETE FROM public.gdl
WHERE rpt_date=in_rpt_date and abi NOT IN (SELECT abi FROM import.gdl);

end
$$;


ALTER PROCEDURE public.p_sync_gdl(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_instrument(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_instrument(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.instrument;
IF size = 0 THEN 
RETURN;
END IF;

insert
	into
	public.instrument
(instrument_type,
    instrument_key,
    rpt_date,
    asset_class_key,
    country,
    created_on,
    currency,
    description,
    isin,
    issuer_key,
    price_key,
    rating_key,
    ratings,
    sub_type,
    type,
    calc,
    data,
    duration,
    exchange,
    residual_life,
    ytm,
    ticker
)
select
src.instrument_type,
    src.instrument_key,
    in_rpt_date as rpt_date,
    src.asset_class_key,
    src.country,
    src.created_on,
    src.currency,
    src.description,
    src.isin,
    src.issuer_key,
    src.price_key,
    src.rating_key,
    src.ratings,
    src.sub_type,
    src.type,
    src.calc,
    src.data,
    src.duration,
    src.exchange,
    src.residual_life,
    src.ytm,
    src.ticker
from import.instrument src
ON CONFLICT(rpt_date, instrument_key) DO
UPDATE SET
instrument_type = excluded.instrument_type,
    asset_class_key = excluded.asset_class_key,
    country = excluded.country,
    created_on = excluded.created_on,
    currency = excluded.currency,
    description = excluded.description,
    isin = excluded.isin,
    issuer_key = excluded.issuer_key,
    price_key = excluded.price_key,
    rating_key = excluded.rating_key,
    ratings = excluded.ratings,
    sub_type = excluded.sub_type,
    type = excluded.type,
    calc = excluded.calc,
    data = excluded.data,
    duration = excluded.duration,
    exchange = excluded.exchange,
    residual_life = excluded.residual_life,
    ytm = excluded.ytm,
    ticker = excluded.ticker;
DELETE FROM public.instrument
WHERE rpt_date=in_rpt_date and instrument_key NOT IN (SELECT instrument_key FROM import.instrument);

end
$$;


ALTER PROCEDURE public.p_sync_instrument(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_limit_value(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_limit_value(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.limit_value;
IF size = 0 THEN 
RETURN;
END IF;
call public.p_limit_value_pre_sync(); 
insert
	into
	public.limit_value
(limit_value_key,
    rpt_date,
    abi,
    created_on,
    ia_description,
    ia_id,
    ia_name,
    ic_description,
    ic_id,
    l1max,
    l1max_perc,
    l1min,
    l1min_perc,
    l2max,
    l2max_perc,
    l2min,
    l2min_perc,
    limit_display,
    limit_key,
    max,
    max_perc,
    min,
    min_perc,
    rl_limit_name,
    rp_exceed,
    rp_in_limits,
    rp_value,
    reference_date
)
select
src.limit_value_key,
    in_rpt_date as rpt_date,
    src.abi,
    src.created_on,
    src.ia_description,
    src.ia_id,
    src.ia_name,
    src.ic_description,
    src.ic_id,
    src.l1max,
    src.l1max_perc,
    src.l1min,
    src.l1min_perc,
    src.l2max,
    src.l2max_perc,
    src.l2min,
    src.l2min_perc,
    src.limit_display,
    src.limit_key,
    src.max,
    src.max_perc,
    src.min,
    src.min_perc,
    src.rl_limit_name,
    src.rp_exceed,
    src.rp_in_limits,
    src.rp_value,
    src.reference_date
from import.limit_value src
ON CONFLICT(rpt_date, limit_value_key) DO
UPDATE SET
abi = excluded.abi,
    created_on = excluded.created_on,
    ia_description = excluded.ia_description,
    ia_id = excluded.ia_id,
    ia_name = excluded.ia_name,
    ic_description = excluded.ic_description,
    ic_id = excluded.ic_id,
    l1max = excluded.l1max,
    l1max_perc = excluded.l1max_perc,
    l1min = excluded.l1min,
    l1min_perc = excluded.l1min_perc,
    l2max = excluded.l2max,
    l2max_perc = excluded.l2max_perc,
    l2min = excluded.l2min,
    l2min_perc = excluded.l2min_perc,
    limit_display = excluded.limit_display,
    limit_key = excluded.limit_key,
    max = excluded.max,
    max_perc = excluded.max_perc,
    min = excluded.min,
    min_perc = excluded.min_perc,
    rl_limit_name = excluded.rl_limit_name,
    rp_exceed = excluded.rp_exceed,
    rp_in_limits = excluded.rp_in_limits,
    rp_value = excluded.rp_value,
    reference_date = excluded.reference_date;
DELETE FROM public.limit_value
WHERE rpt_date=in_rpt_date and limit_value_key NOT IN (SELECT limit_value_key FROM import.limit_value);

end
$$;


ALTER PROCEDURE public.p_sync_limit_value(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_portfolio_info(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_portfolio_info(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.portfolio_info;
IF size = 0 THEN 
RETURN;
END IF;

insert
	into
	public.portfolio_info
(portfolioinfo_key,
    rpt_date,
    abi,
    data_regolamento,
    cash_balance,
    data
)
select
src.portfolioinfo_key,
    in_rpt_date as rpt_date,
    src.abi,
    src.data_regolamento,
    src.cash_balance,
    src.data
from import.portfolio_info src
ON CONFLICT(rpt_date, portfolioinfo_key) DO
UPDATE SET
abi = excluded.abi,
    data_regolamento = excluded.data_regolamento,
    cash_balance = excluded.cash_balance,
    data = excluded.data;
DELETE FROM public.portfolio_info
WHERE rpt_date=in_rpt_date and portfolioinfo_key NOT IN (SELECT portfolioinfo_key FROM import.portfolio_info);

end
$$;


ALTER PROCEDURE public.p_sync_portfolio_info(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_position(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_position(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.position;
IF size = 0 THEN 
RETURN;
END IF;
call public.p_position_pre_sync(); 
insert
	into
	public.position
(position_type,
    position_key,
    rpt_date,
    abi,
    book,
    calc,
    created_on,
    currency,
    data,
    desk,
    instrument_key,
    isin,
    portfolio_key,
    quantity,
    realizedpl,
    unrealizedpl,
    exchange,
    parent_position_key,
    parent_rpt_date,
    risk_pos_key,
    pn,
    mtm,
    ytd_margin_interest_accrual,
    aggiodisaggio,
    costoammortizzato,
    initialreserve,
    finalreserve,
    current_yield,
    current_yield_weight,
    cm_vigil
)
select
src.position_type,
    src.position_key,
    in_rpt_date as rpt_date,
    src.abi,
    src.book,
    src.calc,
    src.created_on,
    src.currency,
    src.data,
    src.desk,
    src.instrument_key,
    src.isin,
    src.portfolio_key,
    src.quantity,
    src.realizedpl,
    src.unrealizedpl,
    src.exchange,
    src.parent_position_key,
    src.parent_rpt_date,
    src.risk_pos_key,
    src.pn,
    src.mtm,
    src.ytd_margin_interest_accrual,
    src.aggiodisaggio,
    src.costoammortizzato,
    src.initialreserve,
    src.finalreserve,
    src.current_yield,
    src.current_yield_weight,
    src.cm_vigil
from import.view_position_include src
ON CONFLICT(rpt_date, position_key) DO
UPDATE SET
position_type = excluded.position_type,
    abi = excluded.abi,
    book = excluded.book,
    calc = excluded.calc,
    created_on = excluded.created_on,
    currency = excluded.currency,
    data = excluded.data,
    desk = excluded.desk,
    instrument_key = excluded.instrument_key,
    isin = excluded.isin,
    portfolio_key = excluded.portfolio_key,
    quantity = excluded.quantity,
    realizedpl = excluded.realizedpl,
    unrealizedpl = excluded.unrealizedpl,
    exchange = excluded.exchange,
    parent_position_key = excluded.parent_position_key,
    parent_rpt_date = excluded.parent_rpt_date,
    risk_pos_key = excluded.risk_pos_key,
    pn = excluded.pn,
    mtm = excluded.mtm,
    ytd_margin_interest_accrual = excluded.ytd_margin_interest_accrual,
    aggiodisaggio = excluded.aggiodisaggio,
    costoammortizzato = excluded.costoammortizzato,
    initialreserve = excluded.initialreserve,
    finalreserve = excluded.finalreserve,
    current_yield = excluded.current_yield,
    current_yield_weight = excluded.current_yield_weight,
    cm_vigil = excluded.cm_vigil;
DELETE FROM public.position
WHERE rpt_date=in_rpt_date and position_key NOT IN (SELECT position_key FROM import.view_position_include);
REFRESH MATERIALIZED VIEW book; 
end
$$;


ALTER PROCEDURE public.p_sync_position(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_risk_market_data(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_risk_market_data(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.risk_market_data;
IF size = 0 THEN 
RETURN;
END IF;

insert
	into
	public.risk_market_data
(rpt_date,
    risk_market_data_key,
    date,
    currency,
    index_name,
    maturity,
    rate,
    term,
    type
)
select
in_rpt_date as rpt_date,
    src.risk_market_data_key,
    src.date,
    src.currency,
    src.index_name,
    src.maturity,
    src.rate,
    src.term,
    src.type
from import.risk_market_data src
ON CONFLICT(rpt_date, risk_market_data_key) DO
UPDATE SET
date = excluded.date,
    currency = excluded.currency,
    index_name = excluded.index_name,
    maturity = excluded.maturity,
    rate = excluded.rate,
    term = excluded.term,
    type = excluded.type;
DELETE FROM public.risk_market_data
WHERE rpt_date=in_rpt_date and risk_market_data_key NOT IN (SELECT risk_market_data_key FROM import.risk_market_data);

end
$$;


ALTER PROCEDURE public.p_sync_risk_market_data(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_risk_market_data_fixing(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_risk_market_data_fixing(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.risk_market_data_fixing;
IF size = 0 THEN 
RETURN;
END IF;

insert
	into
	public.risk_market_data_fixing
(risk_market_data_fixing_key,
    date,
    currency,
    index_name,
    maturity,
    rate,
    term
)
select
src.risk_market_data_fixing_key,
    src.date,
    src.currency,
    src.index_name,
    src.maturity,
    src.rate,
    src.term
from import.risk_market_data_fixing src
ON CONFLICT(date, risk_market_data_fixing_key) DO
UPDATE SET
currency = excluded.currency,
    index_name = excluded.index_name,
    maturity = excluded.maturity,
    rate = excluded.rate,
    term = excluded.term;
DELETE FROM public.risk_market_data_fixing
WHERE rpt_date=in_rpt_date and risk_market_data_fixing_key NOT IN (SELECT risk_market_data_fixing_key FROM import.risk_market_data_fixing);

end
$$;


ALTER PROCEDURE public.p_sync_risk_market_data_fixing(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_risk_pos(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_risk_pos(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.risk_pos;
IF size = 0 THEN 
RETURN;
END IF;

insert
	into
	public.risk_pos
(risk_pos_key,
    rpt_date,
    cr01,
    es,
    il01,
    ir01,
    isin_code,
    ivar,
    mvar,
    var_1d,
    abi,
    amount_eur,
    asset_code,
    description,
    desk,
    pid,
    portfolio_key,
    reference_date,
    weight,
    mtm
)
select
src.risk_pos_key,
    in_rpt_date as rpt_date,
    src.cr01,
    src.es,
    src.il01,
    src.ir01,
    src.isin_code,
    src.ivar,
    src.mvar,
    src.var_1d,
    src.abi,
    src.amount_eur,
    src.asset_code,
    src.description,
    src.desk,
    src.pid,
    src.portfolio_key,
    src.reference_date,
    src.weight,
    src.mtm
from import.risk_pos src
ON CONFLICT(rpt_date, risk_pos_key) DO
UPDATE SET
cr01 = excluded.cr01,
    es = excluded.es,
    il01 = excluded.il01,
    ir01 = excluded.ir01,
    isin_code = excluded.isin_code,
    ivar = excluded.ivar,
    mvar = excluded.mvar,
    var_1d = excluded.var_1d,
    abi = excluded.abi,
    amount_eur = excluded.amount_eur,
    asset_code = excluded.asset_code,
    description = excluded.description,
    desk = excluded.desk,
    pid = excluded.pid,
    portfolio_key = excluded.portfolio_key,
    reference_date = excluded.reference_date,
    weight = excluded.weight,
    mtm = excluded.mtm;
DELETE FROM public.risk_pos
WHERE rpt_date=in_rpt_date and risk_pos_key NOT IN (SELECT risk_pos_key FROM import.risk_pos);

end
$$;


ALTER PROCEDURE public.p_sync_risk_pos(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_risk_ptf(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_risk_ptf(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.risk_ptf;
IF size = 0 THEN 
RETURN;
END IF;

insert
	into
	public.risk_ptf
(risk_ptf_key,
    rpt_date,
    aggregation_name,
    es,
    ivar,
    mvar,
    var_1d,
    abi,
    desk,
    portfolio_key,
    reference_date,
    cr01,
    il01,
    ir01
)
select
src.risk_ptf_key,
    in_rpt_date as rpt_date,
    src.aggregation_name,
    src.es,
    src.ivar,
    src.mvar,
    src.var_1d,
    src.abi,
    src.desk,
    src.portfolio_key,
    src.reference_date,
    src.cr01,
    src.il01,
    src.ir01
from import.risk_ptf src
ON CONFLICT(rpt_date, risk_ptf_key) DO
UPDATE SET
aggregation_name = excluded.aggregation_name,
    es = excluded.es,
    ivar = excluded.ivar,
    mvar = excluded.mvar,
    var_1d = excluded.var_1d,
    abi = excluded.abi,
    desk = excluded.desk,
    portfolio_key = excluded.portfolio_key,
    reference_date = excluded.reference_date,
    cr01 = excluded.cr01,
    il01 = excluded.il01,
    ir01 = excluded.ir01;
DELETE FROM public.risk_ptf
WHERE rpt_date=in_rpt_date and risk_ptf_key NOT IN (SELECT risk_ptf_key FROM import.risk_ptf);

end
$$;


ALTER PROCEDURE public.p_sync_risk_ptf(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_trade(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_trade(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.trade;
IF size = 0 THEN 
RETURN;
END IF;

insert
	into
	public.trade
(rpt_date,
    trade_key,
    starts_on
)
select
in_rpt_date as rpt_date,
    src.trade_key,
    src.starts_on
from import.trade src
ON CONFLICT(rpt_date, trade_key) DO
UPDATE SET
starts_on = excluded.starts_on;
DELETE FROM public.trade
WHERE rpt_date=in_rpt_date and trade_key NOT IN (SELECT trade_key FROM import.trade);

end
$$;


ALTER PROCEDURE public.p_sync_trade(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_sync_trade_reconciliation(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_sync_trade_reconciliation(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
DECLARE size integer;
begin
SELECT COUNT(1) INTO size 
   FROM import.trade_reconciliation;
IF size = 0 THEN 
RETURN;
END IF;

insert
	into
	public.trade_reconciliation
(trade_reconciliation_key,
    isin,
    desk,
    book,
    abi,
    trade_quantity,
    position_quantity,
    rpt_date,
    status,
    trade_key
)
select
src.trade_reconciliation_key,
    src.isin,
    src.desk,
    src.book,
    src.abi,
    src.trade_quantity,
    src.position_quantity,
    in_rpt_date as rpt_date,
    src.status,
    src.trade_key
from import.trade_reconciliation src
ON CONFLICT(rpt_date, trade_reconciliation_key) DO
UPDATE SET
isin = excluded.isin,
    desk = excluded.desk,
    book = excluded.book,
    abi = excluded.abi,
    trade_quantity = excluded.trade_quantity,
    position_quantity = excluded.position_quantity,
    status = excluded.status,
    trade_key = excluded.trade_key;
DELETE FROM public.trade_reconciliation
WHERE rpt_date=in_rpt_date and trade_reconciliation_key NOT IN (SELECT trade_reconciliation_key FROM import.trade_reconciliation);

end
$$;


ALTER PROCEDURE public.p_sync_trade_reconciliation(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_update_multiranking_sector(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_update_multiranking_sector(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$

DECLARE v_countries text[];

BEGIN
    v_countries := ARRAY[
        'US','AU','CA','CH','DK',
        'GB','HK','JP','MX','NO',
        'NZ','SG','SE','AT','BE',
        'CY','EE','FI','FR','DE',
        'GR','IE','LV','LT','LU',
        'MT','NL','PT','SK','SI',
        'ES','SNAT'
    ];

    -- Clear instrument
    update instrument
    set asset_class_key = null
    where rpt_date = in_rpt_date
    and asset_class_key is not null;

    -- For equities, asset_class is equal to sub_type
    update instrument
    set asset_class_key = sub_type
    where rpt_date = in_rpt_date
    and instrument_type = 'EQUITY'
    and asset_class_key is NULL;

    -- For swap, asset_class is the same as instrument_type
    update instrument
    set asset_class_key = 'SWAP'
    where rpt_date = in_rpt_date
    and instrument_type = 'SWAP'
    and asset_class_key is NULL;

    -- For bond (ie: not SWAP nor EQUITY), the asset_class should be IT for italian GOV
    update instrument
    set asset_class_key='IT'
    where rpt_date = in_rpt_date
    and instrument_type not in ('SWAP', 'EQUITY')
    and country='IT'
    and data->>'sector' = 'GOVI';

    -- For bonds, asset_class if GOV if GOV sector and country not IT but in the list
    update instrument
    set asset_class_key='GOV'
    where rpt_date = in_rpt_date
    and instrument_type not in ('SWAP', 'EQUITY')
    and data->>'sector' = 'GOVI'
    and country = ANY(v_countries);

    -- Update asset_class to EMK for GOVI and countries not in the list
    update instrument
    set asset_class_key='EMK'
    where rpt_date = in_rpt_date
    and instrument_type not in ('SWAP', 'EQUITY')
    and data->>'sector' = 'GOVI'
    and not (country = ANY(array_append(v_countries, 'IT')));

    -- Update asset_class fin
    update instrument
    set asset_class_key='FIN'
    where rpt_date = in_rpt_date
    and instrument_type not in ('SWAP', 'EQUITY')
    and data->>'sector' = 'FINANCE';

    -- Update asset_class CORP for non GOVI nor FINANCE
    update instrument
    set asset_class_key='CORP'
    where rpt_date = in_rpt_date
    and instrument_type not in ('SWAP', 'EQUITY')
    and data->>'sector' not in ('GOVI', 'FINANCE');

    -- Update asset_class to GOV if no sector for countries in the list
    update instrument
    set asset_class_key='GOV'
    where rpt_date = in_rpt_date
    and instrument_type not in ('SWAP', 'EQUITY')
    and data->>'sector' is null
    and country = ANY(array_append(v_countries, 'IT'));

    -- Update asset_class to EMK if no sector for countries NOT in the list
    update instrument
    set asset_class_key='EMK'
    where rpt_date = in_rpt_date
    and instrument_type not in ('SWAP', 'EQUITY')
    and data->>'sector' is null
    and not (country = ANY(array_append(v_countries, 'IT')));

END
$$;


ALTER PROCEDURE public.p_update_multiranking_sector(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_update_percentile(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_update_percentile(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- p_amt_out
    with iTemp as (
        select i.rpt_date, i.instrument_key, (i.data ->> 'amtOut')::numeric as field from instrument i
        where i.rpt_date = in_rpt_date
          and (data ->> 'amtOut') is not null
    ), iCount as (select count(*)::numeric/100 from iTemp)
    update instrument
    set p_amt_out =( (select count(*)::numeric from iTemp i2 where i2.field <= iTemp.field)/(select * from iCount) )
    from iTemp
    where instrument.rpt_date = in_rpt_date
      and instrument.instrument_key = iTemp.instrument_key;

-- p_duration
    with iTemp as (
        select i.rpt_date, i.instrument_key, i.duration as field from instrument i
        where i.rpt_date = in_rpt_date
          and duration is not null
    ), iCount as (select count(*)::numeric/100 from iTemp)
    update instrument
    set p_duration =( (select count(*)::numeric from iTemp i2 where i2.field <= iTemp.field)/(select * from iCount) )
    from iTemp
    where instrument.rpt_date = in_rpt_date
      and instrument.instrument_key = iTemp.instrument_key;

-- p_residual_life
    with iTemp as (
        select i.rpt_date, i.instrument_key, i.residual_life as field from instrument i
        where i.rpt_date = in_rpt_date
          and residual_life is not null
    ), iCount as (select count(*)::numeric/100 from iTemp)
    update instrument
    set p_residual_life =( (select count(*)::numeric from iTemp i2 where i2.field <= iTemp.field)/(select * from iCount) )
    from iTemp
    where instrument.rpt_date = in_rpt_date
      and instrument.instrument_key = iTemp.instrument_key;

-- lottoMinimo
    with iTemp as (
        select i.rpt_date, i.instrument_key, (i.data ->> 'lottoMinimo')::numeric as field from instrument i
        where i.rpt_date = in_rpt_date
          and (data ->> 'lottoMinimo') is not null
    ), iCount as (select count(*)::numeric/100 from iTemp)
    update instrument
    set p_lotto_minimo =( (select count(*)::numeric from iTemp i2 where i2.field <= iTemp.field)/(select * from iCount) )
    from iTemp
    where instrument.rpt_date = in_rpt_date
      and instrument.instrument_key = iTemp.instrument_key;

-- ytm
    with iTemp as (
        select i.rpt_date, i.instrument_key, i.ytm as field from instrument i
        where i.rpt_date = in_rpt_date
          and ytm is not null
    ), iCount as (select count(*)::numeric/100 from iTemp)
    update instrument
    set p_ytm =( (select count(*)::numeric from iTemp i2 where i2.field <= iTemp.field)/(select * from iCount) )
    from iTemp
    where instrument.rpt_date = in_rpt_date
      and instrument.instrument_key = iTemp.instrument_key;

-- p_iscoring
    with iTemp as (
        select i.rpt_date, i.instrument_key, rr.ord as field from instrument i join ref_rating rr on rr.cn_sensus = i.ratings ->> 'CNSENSUS'
        where i.rpt_date = in_rpt_date and rr.ord is not null
    ), iCount as (select count(*)::numeric/100 from iTemp)
    update instrument
    set p_iscoring =( (select count(*)::numeric from iTemp i2 where i2.field <= iTemp.field)/(select * from iCount) )
    from iTemp
    where instrument.rpt_date = in_rpt_date
      and instrument.instrument_key = iTemp.instrument_key;


END;
$$;


ALTER PROCEDURE public.p_update_percentile(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_update_percentile_price(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_update_percentile_price(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- p_price
-- p_price
-- join con tabella price
--     with iTemp as (
--         select i.rpt_date, i.instrument_key, i.p_price, pp.price as field from instrument i join price pp on pp.price_key = i.isin
--         where i.rpt_date = in_rpt_date
--     ), iCount as (select count(*)::float/100 from iTemp)
--     update instrument
--     set p_price =( (select count(*)::float from iTemp i2 where i2.field <= iTemp.field)/(select * from iCount) )
--     from iTemp
--     where instrument.rpt_date = in_rpt_date
--       and instrument.instrument_key = iTemp.instrument_key;
--

    with iTemp as (
        select i.rpt_date, i.instrument_key, (i.calc ->> 'cleanPrice')::float as field from instrument i
        where i.rpt_date = in_rpt_date
          and (calc ->> 'cleanPrice') is not null
    ), iCount as (select count(*)::numeric/100 from iTemp)
    update instrument
    set p_price =( (select count(*)::numeric from iTemp i2 where i2.field <= iTemp.field)/(select * from iCount) )
    from iTemp
    where instrument.rpt_date = in_rpt_date
      and instrument.instrument_key = iTemp.instrument_key;

END;
$$;


ALTER PROCEDURE public.p_update_percentile_price(in_rpt_date date) OWNER TO exa_db;

--
-- Name: p_upsert_limit_value(date, character varying, date, character varying, character varying, character varying, character varying, character varying, character varying, character varying, character varying, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, character varying, boolean, character varying, numeric); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.p_upsert_limit_value(in_rpt_date date, in_limit_value_key character varying, in_reference_date date, in_limit_key character varying, in_limit_display character varying, in_abi character varying, in_ia_id character varying, in_ia_name character varying, in_ia_description character varying, in_ic_id character varying, in_ic_description character varying, in_l1max numeric, in_l1max_perc numeric, in_l1min numeric, in_l1min_perc numeric, in_l2max numeric, in_l2max_perc numeric, in_l2min numeric, in_l2min_perc numeric, in_max numeric, in_max_perc numeric, in_min numeric, in_min_perc numeric, in_rl_limit_name character varying, in_rp_exceed boolean, in_rp_in_limits character varying, in_rp_value numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN

    insert into limit_value(
        rpt_date, limit_value_key,
        reference_date,
        limit_key, limit_display, abi,
        ia_id, ia_name, ia_description, ic_id, ic_description,
        l1max, l1max_perc, l1min, l1min_perc,
        l2max, l2max_perc, l2min, l2min_perc,
        max, max_perc, min, min_perc,
        rl_limit_name, rp_exceed, rp_in_limits, rp_value,
        created_on
    )
    VALUES (
        in_rpt_date, in_limit_value_key,
        in_reference_date,
        in_limit_key, in_limit_display, in_abi,
        in_ia_id, in_ia_name, in_ia_description, in_ic_id, in_ic_description,
        in_l1max, in_l1max_perc, in_l1min, in_l1min_perc,
        in_l2max, in_l2max_perc, in_l2min, in_l2min_perc,
        in_max, in_max_perc, in_min, in_min_perc,
        in_rl_limit_name, in_rp_exceed, in_rp_in_limits, in_rp_value,
        now()
    )
    on conflict on constraint limit_value_pkey
    do update
        SET limit_key = in_limit_key,
            reference_date = in_reference_date,
            limit_display = in_limit_display,
            abi = in_abi,

            ia_id = in_ia_id,
            ia_name = in_ia_name,
            ia_description = in_ia_description,
            ic_id = in_ic_id,
            ic_description = in_ic_description,

            l1max = in_l1max,
            l1max_perc = in_l1max_perc,
            l1min = in_l1min,
            l1min_perc = in_l1min_perc,

            l2max = in_l2max,
            l2max_perc = in_l2max_perc,
            l2min = in_l2min,
            l2min_perc = in_l2min_perc,

            max = in_max,
            max_perc = in_max_perc,
            min = in_min,
            min_perc = in_min_perc,

            rl_limit_name = in_rl_limit_name,
            rp_exceed = in_rp_exceed,
            rp_in_limits = in_rp_in_limits,
            rp_value = in_rp_value,
            created_on = now()
        WHERE
            limit_value.limit_value_key = in_limit_value_key
            AND limit_value.rpt_date = in_rpt_date
    ;
END
$$;


ALTER PROCEDURE public.p_upsert_limit_value(in_rpt_date date, in_limit_value_key character varying, in_reference_date date, in_limit_key character varying, in_limit_display character varying, in_abi character varying, in_ia_id character varying, in_ia_name character varying, in_ia_description character varying, in_ic_id character varying, in_ic_description character varying, in_l1max numeric, in_l1max_perc numeric, in_l1min numeric, in_l1min_perc numeric, in_l2max numeric, in_l2max_perc numeric, in_l2min numeric, in_l2min_perc numeric, in_max numeric, in_max_perc numeric, in_min numeric, in_min_perc numeric, in_rl_limit_name character varying, in_rp_exceed boolean, in_rp_in_limits character varying, in_rp_value numeric) OWNER TO exa_db;

--
-- Name: test_procedure(); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.test_procedure()
    LANGUAGE plpgsql
    AS $$

DECLARE
   

BEGIN
    ALTER TABLE import.xm_finance 
	ADD COLUMN test_prova VARCHAR(100);

END
$$;


ALTER PROCEDURE public.test_procedure() OWNER TO exa_db;

--
-- Name: trade_hist_upsert(); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.trade_hist_upsert()
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_now timestamp;
    v_default_ends_on timestamp;

begin
	
	-- testare caso di tradeStatus = CANC e poi torna a "DONE | VER"

	select to_char(current_timestamp::timestamp,'YYYY-MM-DD HH24:MI:SS.SSSSS') into v_now;
    select to_char(cast('3000-01-01 00:00:00.000' AS timestamp),'YYYY-MM-DD HH24:MI:SS.SSSSS') into v_default_ends_on;

   -- Setto ends_on a now perchè quel record diventerà storico 
   
	update
		public.trade_hist t
	set
		ends_on = v_now
	from
		import.eefgbci_bond v
	where
		v.eefgbci_bond_key = t.trade_key
		and ends_on = v_default_ends_on
		and v.process = false;
    

	-- Inserisco un nuovo record con ends_on = v_default_ends_on per tutti quelli aggiornati con l'update sopra

    insert into public.trade_hist(trade_key, abi, book, desk, isin, notional,
	    clean_price, trade_status, trade_entry_date, settle_date, ext_trade_id,
	    trade_date, pors, company, row_hash, starts_on, ends_on, deleted, execution_datetime
	)
    select
	v.eefgbci_bond_key,
	v.abi,
	v.book,
	v.desk,
	v.isin,
	v.notional,
	v.clean_price,
	v.trade_status,
	v.trade_entry_date,
	v.settle_date,
	v.ext_trade_id,
	v.trade_date,
	v.pors,
	v.company,
	v.row_hash,
	v_now as starts_on,
	 v_default_ends_on as ends_on,
	 case 
		 when v.trade_status = 'CANC' then true
		 when v.trade_status != 'CANC' then false
	end as deleted,
	v.execution_datetime
	from
		import.eefgbci_bond v
	join public.trade_hist t
		on v.eefgbci_bond_key = t.trade_key
		and v.process  = false
	where
		t.ends_on = v_now;

	
	-- Aggiorno sulla tabella import il boolean process settandolo a true cosi da non ri-processare record già lavorati
	
	update
		import.eefgbci_bond v
	set
		process = true
	from
		public.trade_hist t
	where
		v.eefgbci_bond_key = t.trade_key
		and ends_on = v_default_ends_on
		and v.process = false;
   

    
    -- Tutto quello che rimane con process = false va inserito con deleted = false perche corrisponde a un nuovo tradeId
    insert into public.trade_hist(trade_key, abi, book, desk, isin, notional,
    	clean_price, trade_status, trade_entry_date, settle_date, ext_trade_id,
    	trade_date, pors, company, row_hash, starts_on, ends_on, deleted, execution_datetime
    )
    select
        t.eefgbci_bond_key ,
        t.abi,
        t.book,
        t.desk,
        t.isin,
        t.notional,
        t.clean_price,
        t.trade_status,
        t.trade_entry_date,
        t.settle_date,
        t.ext_trade_id,
        t.trade_date,
        t.pors,
        t.company,
        t.row_hash,
        v_now as starts_on,
        v_default_ends_on as ends_on,
        false as deleted,
        t.execution_datetime
    from import.eefgbci_bond t
    where t.process = false
    and t.trade_status in ('DONE','VER');
   
   	update
		import.eefgbci_bond v
	set
		process = true
	where
		v.trade_status in ('DONE','VER')
		and v.process = false;



END
$$;


ALTER PROCEDURE public.trade_hist_upsert() OWNER TO exa_db;

--
-- Name: update_percentile(date); Type: PROCEDURE; Schema: public; Owner: exa_db
--

CREATE PROCEDURE public.update_percentile(in_rpt_date date)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- p_amt_out
    update instrument
    set p_amt_out = (
        select count(*)::float from instrument p
        where p.rpt_date = in_rpt_date
        and (p.data ->> 'amtOut') is not null
        and cast(p.data ->> 'amtOut' as numeric) <= cast(instrument.data ->> 'amtOut' as numeric)
    ) / (
        select count(*)::float from instrument t
        where t.rpt_date = in_rpt_date
        and (t.data ->> 'amtOut') is not null
    ) * 100
    where rpt_date = in_rpt_date
    and (data ->> 'amtOut') is not null;

    -- p_duration
    update instrument
    set p_duration = (
        select count(*)::float from instrument p
        where p.rpt_date = in_rpt_date
        and p.duration is not null
        and p.duration <= instrument.duration
    ) / (
        select count(*)::float from instrument t
        where t.rpt_date = in_rpt_date
        and t.duration is not null
    ) * 100
    where rpt_date = in_rpt_date
    and duration is not null;

    -- p_residual_life
    update instrument
    set p_residual_life = (
        select count(*)::float from instrument p
        where p.rpt_date = in_rpt_date
        and p.residual_life is not null
        and p.residual_life <= instrument.residual_life
    ) / (
        select count(*)::float from instrument t
        where t.rpt_date = in_rpt_date
        and t.residual_life is not null
    ) * 100
    where rpt_date = in_rpt_date
    and residual_life is not null;

    -- lottoMinimo
    update instrument
    set p_lotto_minimo = (
        select count(*)::float from instrument p
        where p.rpt_date = in_rpt_date
        and (p.data ->> 'lottoMinimo') is not null
        and cast(p.data ->> 'lottoMinimo' as numeric) <= cast(instrument.data ->> 'lottoMinimo' as numeric)
    ) / (
        select count(*)::float from instrument t
        where t.rpt_date = in_rpt_date
        and (t.data ->> 'lottoMinimo') is not null
    ) * 100
    where rpt_date = in_rpt_date
    and (data ->> 'lottoMinimo') is not null;

    -- ytm
    update instrument
    set p_ytm = (
        select count(*)::float from instrument p
        where p.rpt_date = in_rpt_date
        and p.ytm is not null
        and p.ytm <= instrument.ytm
    ) / (
        select count(*)::float from instrument t
        where t.rpt_date = in_rpt_date
        and t.ytm is not null
    ) * 100
    where rpt_date = in_rpt_date
    and instrument.ytm is not null;

    /*
    For bond use calc -> cleanPrice (ie: not EQUITY nor SWAP)
    For equity use data -> avgPrice
    */
    -- p_price
    update instrument
    set p_price = (
        select count(*)::float from instrument a join price pp on pp.price_key = a.isin
        where a.rpt_date = in_rpt_date
        and pp.price <= p.price
    ) / (
        select count(*)::float from instrument t join price pt on pt.price_key = t.isin
        where t.rpt_date = in_rpt_date
    ) * 100
    from price p
    where instrument.rpt_date = in_rpt_date
    and instrument.isin = p.price_key
    and p.isin = instrument.isin;

    -- p_iscoring
    update instrument
    set p_iscoring = (
        select count(*)::float from instrument p join ref_rating pr on pr.cn_sensus = p.ratings ->> 'CNSENSUS'
        where p.rpt_date = in_rpt_date
        and pr.ord is not null
        and pr.ord <= r.ord
    ) / (
        select count(*)::float from instrument t join ref_rating pt on pt.cn_sensus = t.ratings ->> 'CNSENSUS'
        where t.rpt_date = in_rpt_date
        and pt.ord is not null
        and pt.ord <= r.ord
    ) * 100
    from ref_rating r
    where instrument.rpt_date = in_rpt_date
    and r.cn_sensus = instrument.ratings ->> 'CNSENSUS'
    and r.ord is not null;
END;
$$;


ALTER PROCEDURE public.update_percentile(in_rpt_date date) OWNER TO exa_db;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: abi_gdl; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.abi_gdl (
    abi character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.abi_gdl OWNER TO exa_db;

--
-- Name: bond_def_cashflows; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.bond_def_cashflows (
    securityid character varying,
    ccy character varying,
    date character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.bond_def_cashflows OWNER TO exa_db;

--
-- Name: bus_model; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.bus_model (
    position_type character varying(31) NOT NULL,
    position_key character varying(100) NOT NULL,
    bus_model character varying NOT NULL,
    rpt_date date NOT NULL,
    abi character varying(255),
    book character varying(255),
    calc jsonb,
    created_on timestamp without time zone,
    currency character varying(255),
    data jsonb,
    desk character varying(255),
    instrument_key character varying(255),
    isin character varying(255),
    portfolio_key character varying(255),
    quantity numeric(19,4),
    realizedpl numeric(19,4),
    unrealizedpl numeric(19,4),
    exchange character varying(255),
    parent_position_key character varying(100),
    parent_rpt_date date,
    risk_pos_key character varying(100),
    pn numeric(19,4),
    mtm numeric(19,4),
    ytd_margin_interest_accrual numeric(19,4),
    aggiodisaggio numeric(19,4),
    costoammortizzato numeric(19,4),
    initialreserve numeric(19,4),
    finalreserve numeric(19,4),
    current_yield numeric(19,4),
    current_yield_weight numeric(19,4),
    cm_vigil numeric(19,4)
);


ALTER TABLE import.bus_model OWNER TO exa_db;

--
-- Name: bus_model_copy; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.bus_model_copy (
    position_type character varying(31),
    position_key character varying(100),
    bus_model character varying,
    rpt_date date,
    abi character varying(255),
    book character varying(255),
    calc jsonb,
    created_on timestamp without time zone,
    currency character varying(255),
    data jsonb,
    desk character varying(255),
    instrument_key character varying(255),
    isin character varying(255),
    portfolio_key character varying(255),
    quantity numeric(19,4),
    realizedpl numeric(19,4),
    unrealizedpl numeric(19,4),
    exchange character varying(255),
    parent_position_key character varying(100),
    parent_rpt_date date,
    risk_pos_key character varying(100),
    pn numeric(19,4),
    mtm numeric(19,4),
    ytd_margin_interest_accrual numeric(19,4),
    aggiodisaggio numeric(19,4),
    costoammortizzato numeric(19,4),
    initialreserve numeric(19,4),
    finalreserve numeric(19,4),
    current_yield numeric(19,4),
    current_yield_weight numeric(19,4),
    cm_vigil numeric(19,4)
);


ALTER TABLE import.bus_model_copy OWNER TO exa_db;

--
-- Name: customer; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.customer (
    id character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.customer OWNER TO exa_db;

--
-- Name: eefgbci_bond; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.eefgbci_bond (
    eefgbci_bond_key character varying NOT NULL,
    abi character varying,
    desk character varying,
    book character varying,
    isin character varying,
    notional numeric(19,4),
    clean_price numeric(19,4),
    trade_status character varying,
    trade_entry_date date,
    settle_date date,
    ext_trade_id character varying,
    trade_date date,
    pors character varying,
    company character varying,
    row_hash character varying,
    execution_datetime timestamp without time zone,
    process boolean DEFAULT false
);


ALTER TABLE import.eefgbci_bond OWNER TO exa_db;

--
-- Name: eefgbci_bond_export; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.eefgbci_bond_export (
    tradeid character varying,
    company character varying,
    tradestatus character varying,
    desk character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.eefgbci_bond_export OWNER TO exa_db;

--
-- Name: eefgbci_bond_tmp_20231207; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.eefgbci_bond_tmp_20231207 (
    eefgbci_bond_key character varying,
    abi character varying,
    desk character varying,
    book character varying,
    isin character varying,
    notional numeric(19,4),
    clean_price numeric(19,4),
    trade_status character varying,
    trade_entry_date date,
    settle_date date,
    ext_trade_id character varying,
    trade_date date,
    pors character varying,
    company character varying,
    row_hash character varying,
    execution_datetime timestamp without time zone,
    process boolean
);


ALTER TABLE import.eefgbci_bond_tmp_20231207 OWNER TO exa_db;

--
-- Name: eefgbci_swap_export; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.eefgbci_swap_export (
    tradeid character varying,
    legtype character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.eefgbci_swap_export OWNER TO exa_db;

--
-- Name: eefgbci_swap_trdetrep_cashflows; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.eefgbci_swap_trdetrep_cashflows (
    generatedpk character varying,
    tradeid character varying,
    legtype character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.eefgbci_swap_trdetrep_cashflows OWNER TO exa_db;

--
-- Name: eefgbci_swap_trdetrep_tradedescription; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.eefgbci_swap_trdetrep_tradedescription (
    generatedpk character varying,
    tradeid character varying,
    legtype character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.eefgbci_swap_trdetrep_tradedescription OWNER TO exa_db;

--
-- Name: eefgbci_swap_trdetrep_tradevaluation; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.eefgbci_swap_trdetrep_tradevaluation (
    generatedpk character varying,
    tradeid character varying,
    legtype character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.eefgbci_swap_trdetrep_tradevaluation OWNER TO exa_db;

--
-- Name: finance; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.finance (
    finance_key character varying,
    rpt_date date,
    abi character varying,
    modello_di_business character varying,
    sub_modello_di_business character varying,
    isin character varying,
    x5_quantity numeric(18,4),
    xm_quantity numeric(18,4),
    saldo_summit numeric(18,4),
    difference numeric(18,4),
    saldo_finance numeric(18,4),
    desk character varying,
    book character varying,
    currency character varying,
    status character varying
);


ALTER TABLE import.finance OWNER TO exa_db;

--
-- Name: gdl; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.gdl (
    rpt_date date NOT NULL,
    abi character varying NOT NULL
);


ALTER TABLE import.gdl OWNER TO exa_db;

--
-- Name: instrument; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.instrument (
    instrument_type character varying(31) NOT NULL,
    instrument_key character varying(100) NOT NULL,
    rpt_date date NOT NULL,
    asset_class_key character varying(255),
    country character varying(255),
    created_on timestamp without time zone,
    currency character varying(255),
    description character varying(255),
    isin character varying(12),
    issuer_key character varying(255),
    p_amt_out numeric(19,2),
    p_duration numeric(19,2),
    p_iscoring numeric(19,2),
    p_lotto_minimo numeric(19,2),
    p_price numeric(19,2),
    p_residual_life numeric(19,2),
    p_ytm numeric(19,2),
    price_key character varying(255),
    rating_key integer,
    ratings jsonb,
    sub_type character varying(255),
    type character varying(255),
    calc jsonb,
    data jsonb,
    duration numeric(19,4),
    exchange character varying(255),
    residual_life numeric(19,4),
    ytm numeric(19,4),
    ticker character varying(255)
);


ALTER TABLE import.instrument OWNER TO exa_db;

--
-- Name: limit_value; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.limit_value (
    limit_value_key character varying(255) NOT NULL,
    rpt_date date NOT NULL,
    abi character varying(255),
    created_on timestamp without time zone,
    ia_description character varying(255),
    ia_id character varying(255),
    ia_name character varying(255),
    ic_description character varying(255),
    ic_id character varying(255),
    l1max numeric(19,2),
    l1max_perc numeric(19,6),
    l1min numeric(19,2),
    l1min_perc numeric(19,6),
    l2max numeric(19,2),
    l2max_perc numeric(19,6),
    l2min numeric(19,2),
    l2min_perc numeric(19,6),
    limit_display character varying(255),
    limit_key character varying(255),
    max numeric(19,2),
    max_perc numeric(19,6),
    min numeric(19,2),
    min_perc numeric(19,6),
    rl_limit_name character varying(255),
    rp_exceed boolean,
    rp_in_limits character varying(255),
    rp_value numeric(19,6),
    perc_max numeric(19,2),
    perc_min numeric(19,2),
    reference_date date
);


ALTER TABLE import.limit_value OWNER TO exa_db;

--
-- Name: limit_value_tmp; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.limit_value_tmp (
    limit_value_key character varying(255),
    rpt_date date,
    abi character varying(255),
    created_on timestamp without time zone,
    ia_description character varying(255),
    ia_id character varying(255),
    ia_name character varying(255),
    ic_description character varying(255),
    ic_id character varying(255),
    l1max numeric(19,2),
    l1max_perc numeric(19,6),
    l1min numeric(19,2),
    l1min_perc numeric(19,6),
    l2max numeric(19,2),
    l2max_perc numeric(19,6),
    l2min numeric(19,2),
    l2min_perc numeric(19,6),
    limit_display character varying(255),
    limit_key character varying(255),
    max numeric(19,2),
    max_perc numeric(19,6),
    min numeric(19,2),
    min_perc numeric(19,6),
    rl_limit_name character varying(255),
    rp_exceed boolean,
    rp_in_limits character varying(255),
    rp_value numeric(19,6),
    perc_max numeric(19,2),
    perc_min numeric(19,2),
    reference_date date
);


ALTER TABLE import.limit_value_tmp OWNER TO exa_db;

--
-- Name: location; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.location (
    loccustid character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.location OWNER TO exa_db;

--
-- Name: m50; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.m50 (
    abi character varying,
    categoria character varying,
    conto character varying,
    dataregolamento character varying,
    importo character varying,
    segno character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.m50 OWNER TO exa_db;

--
-- Name: portfolio_info; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.portfolio_info (
    portfolioinfo_key character varying NOT NULL,
    rpt_date date NOT NULL,
    abi character varying NOT NULL,
    cash_balance numeric(18,4) NOT NULL,
    data_regolamento date NOT NULL,
    data jsonb
);


ALTER TABLE import.portfolio_info OWNER TO exa_db;

--
-- Name: position; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import."position" (
    position_type character varying(31) NOT NULL,
    position_key character varying(100) NOT NULL,
    rpt_date date NOT NULL,
    abi character varying(255),
    book character varying(255),
    calc jsonb,
    created_on timestamp without time zone,
    currency character varying(255),
    data jsonb,
    desk character varying(255),
    instrument_key character varying(255),
    isin character varying(255),
    portfolio_key character varying(255),
    quantity numeric(19,4),
    realizedpl numeric(19,4),
    unrealizedpl numeric(19,4),
    exchange character varying(255),
    parent_position_key character varying(100),
    parent_rpt_date date,
    risk_pos_key character varying(100),
    pn numeric(19,4),
    mtm numeric(19,4),
    ytd_margin_interest_accrual numeric(19,4),
    aggiodisaggio numeric(19,4),
    costoammortizzato numeric(19,4),
    initialreserve numeric(19,4),
    current_yield numeric(19,4),
    current_yield_weight numeric(19,4),
    cm_vigil numeric(19,4),
    finalreserve numeric(19,4),
    include boolean DEFAULT true NOT NULL
);


ALTER TABLE import."position" OWNER TO exa_db;

--
-- Name: position_backup; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.position_backup (
    position_type character varying(31),
    position_key character varying(100),
    rpt_date date,
    abi character varying(255),
    book character varying(255),
    calc jsonb,
    created_on timestamp without time zone,
    currency character varying(255),
    data jsonb,
    desk character varying(255),
    instrument_key character varying(255),
    isin character varying(255),
    portfolio_key character varying(255),
    quantity numeric(19,4),
    realizedpl numeric(19,4),
    unrealizedpl numeric(19,4),
    exchange character varying(255),
    parent_position_key character varying(100),
    parent_rpt_date date,
    risk_pos_key character varying(100),
    pn numeric(19,4),
    mtm numeric(19,4),
    ytd_margin_interest_accrual numeric(19,4),
    aggiodisaggio numeric(19,4),
    costoammortizzato numeric(19,4),
    finalreserve numeric(19,4),
    current_yield numeric(19,4),
    current_yield_weight numeric(19,4),
    cm_vigil numeric(19,4)
);


ALTER TABLE import.position_backup OWNER TO exa_db;

--
-- Name: pzgias; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.pzgias (
    isin character varying,
    ccy character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.pzgias OWNER TO exa_db;

--
-- Name: ref_cod_causale_cad; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.ref_cod_causale_cad (
    id integer NOT NULL,
    cod_causale character varying NOT NULL
);


ALTER TABLE import.ref_cod_causale_cad OWNER TO exa_db;

--
-- Name: ref_cod_causale_cad_id_seq; Type: SEQUENCE; Schema: import; Owner: exa_db
--

CREATE SEQUENCE import.ref_cod_causale_cad_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE import.ref_cod_causale_cad_id_seq OWNER TO exa_db;

--
-- Name: ref_cod_causale_cad_id_seq; Type: SEQUENCE OWNED BY; Schema: import; Owner: exa_db
--

ALTER SEQUENCE import.ref_cod_causale_cad_id_seq OWNED BY import.ref_cod_causale_cad.id;


--
-- Name: ref_finance_ausiliare; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.ref_finance_ausiliare (
    desk character varying,
    book character varying,
    bus_mod character varying,
    sub_bus_mod character varying,
    id integer
);


ALTER TABLE import.ref_finance_ausiliare OWNER TO exa_db;

--
-- Name: ref_position_filter; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.ref_position_filter (
    desk character varying NOT NULL,
    abi character varying NOT NULL,
    to_include boolean NOT NULL,
    created_on timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE import.ref_position_filter OWNER TO exa_db;

--
-- Name: reserve_oci_bond; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.reserve_oci_bond (
    company character varying,
    desk character varying,
    isin character varying,
    generatedpk character varying,
    today character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.reserve_oci_bond OWNER TO exa_db;

--
-- Name: reserve_oci_equity; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.reserve_oci_equity (
    company character varying,
    desk character varying,
    isin character varying,
    generatedpk character varying,
    today character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.reserve_oci_equity OWNER TO exa_db;

--
-- Name: risk_market_data; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.risk_market_data (
    risk_market_data_key character varying(100) NOT NULL,
    rpt_date date NOT NULL,
    currency character varying(255),
    date date,
    index_name character varying(255),
    maturity date,
    rate numeric(19,6),
    term character varying(255),
    type character varying(255)
);


ALTER TABLE import.risk_market_data OWNER TO exa_db;

--
-- Name: risk_pos; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.risk_pos (
    risk_pos_key character varying(100) NOT NULL,
    rpt_date date NOT NULL,
    cr01 numeric(19,2),
    es numeric(19,2),
    il01 numeric(19,2),
    ir01 numeric(19,2),
    isin_code character varying(255),
    ivar numeric(19,2),
    mvar numeric(19,2),
    var_1d numeric(19,2),
    abi character varying(255),
    amount_eur numeric(19,2),
    asset_code character varying(255),
    description character varying(255),
    desk character varying(255),
    pid character varying(255),
    portfolio_key character varying(255),
    reference_date date,
    weight numeric(19,2),
    mtm numeric(19,4)
);


ALTER TABLE import.risk_pos OWNER TO exa_db;

--
-- Name: risk_ptf; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.risk_ptf (
    risk_ptf_key character varying(100) NOT NULL,
    rpt_date date NOT NULL,
    aggregation_name character varying(255),
    es numeric(19,2),
    ivar numeric(19,2),
    mvar numeric(19,2),
    var_1d numeric(19,2),
    abi character varying(255),
    desk character varying(255),
    portfolio_key character varying(255),
    reference_date date,
    cr01 numeric(19,4),
    il01 numeric(19,4),
    ir01 numeric(19,4)
);


ALTER TABLE import.risk_ptf OWNER TO exa_db;

--
-- Name: risk_suite_market_data; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.risk_suite_market_data (
    indexname character varying,
    currency character varying,
    term character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.risk_suite_market_data OWNER TO exa_db;

--
-- Name: risk_suite_risk_limits; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.risk_suite_risk_limits (
    icid character varying,
    abi character varying,
    rllimitname character varying,
    referencedate character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.risk_suite_risk_limits OWNER TO exa_db;

--
-- Name: risk_suite_risk_measures; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.risk_suite_risk_measures (
    portbankid character varying,
    posaggregatename character varying,
    isin character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.risk_suite_risk_measures OWNER TO exa_db;

--
-- Name: risk_suite_risk_measures_aggr; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.risk_suite_risk_measures_aggr (
    portbankid character varying,
    posaggregatename character varying,
    aggregatename character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.risk_suite_risk_measures_aggr OWNER TO exa_db;

--
-- Name: sec; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.sec (
    sec character varying,
    ccy character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.sec OWNER TO exa_db;

--
-- Name: sec_pos_rep; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.sec_pos_rep (
    generatedpk character varying,
    company character varying,
    desk character varying,
    book character varying,
    security character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.sec_pos_rep OWNER TO exa_db;

--
-- Name: stock; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.stock (
    exchange character varying,
    ticker character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.stock OWNER TO exa_db;

--
-- Name: test_jwrite_city; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.test_jwrite_city (
    city_key character(2) NOT NULL,
    city_name character varying(1024)
);


ALTER TABLE import.test_jwrite_city OWNER TO exa_db;

--
-- Name: test_jwrite_main; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.test_jwrite_main (
    id integer NOT NULL,
    city_key character(2),
    amount bigint
);


ALTER TABLE import.test_jwrite_main OWNER TO exa_db;

--
-- Name: test_jwrite_main_id_seq; Type: SEQUENCE; Schema: import; Owner: exa_db
--

CREATE SEQUENCE import.test_jwrite_main_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE import.test_jwrite_main_id_seq OWNER TO exa_db;

--
-- Name: test_jwrite_main_id_seq; Type: SEQUENCE OWNED BY; Schema: import; Owner: exa_db
--

ALTER SEQUENCE import.test_jwrite_main_id_seq OWNED BY import.test_jwrite_main.id;


--
-- Name: trade; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.trade (
    rpt_date date NOT NULL,
    trade_key character varying(100) NOT NULL,
    starts_on timestamp without time zone NOT NULL
);


ALTER TABLE import.trade OWNER TO exa_db;

--
-- Name: trade_pl_bond; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.trade_pl_bond (
    company character varying,
    desk character varying,
    book character varying,
    sec character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.trade_pl_bond OWNER TO exa_db;

--
-- Name: trade_pl_equity; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.trade_pl_equity (
    generatedpk character varying,
    exchange character varying,
    ticker character varying,
    company character varying,
    desk character varying,
    book character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.trade_pl_equity OWNER TO exa_db;

--
-- Name: trade_pl_swap; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.trade_pl_swap (
    generatedpk character varying,
    tradeid character varying,
    legtype character varying,
    company character varying,
    desk character varying,
    book character varying,
    secid character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.trade_pl_swap OWNER TO exa_db;

--
-- Name: trade_plbm_bond; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.trade_plbm_bond (
    company character varying,
    sec character varying,
    ccy character varying,
    businessmodel character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.trade_plbm_bond OWNER TO exa_db;

--
-- Name: trade_reconciliation; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.trade_reconciliation (
    trade_reconciliation_key character varying NOT NULL,
    isin character varying,
    desk character varying,
    book character varying,
    abi character varying,
    trade_quantity numeric(18,4),
    position_quantity numeric(18,4),
    rpt_date date NOT NULL,
    status character varying,
    trade_key character varying
);


ALTER TABLE import.trade_reconciliation OWNER TO exa_db;

--
-- Name: uplift_gebonamo; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.uplift_gebonamo (
    tradeid character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.uplift_gebonamo OWNER TO exa_db;

--
-- Name: view_position_include; Type: VIEW; Schema: import; Owner: exa_db
--

CREATE VIEW import.view_position_include AS
 SELECT p.position_type,
    p.position_key,
    p.rpt_date,
    p.abi,
    p.book,
    p.calc,
    p.created_on,
    p.currency,
    p.data,
    p.desk,
    p.instrument_key,
    p.isin,
    p.portfolio_key,
    p.quantity,
    p.realizedpl,
    p.unrealizedpl,
    p.exchange,
    p.parent_position_key,
    p.parent_rpt_date,
    p.risk_pos_key,
    p.pn,
    p.mtm,
    p.ytd_margin_interest_accrual,
    p.aggiodisaggio,
    p.costoammortizzato,
    p.initialreserve,
    p.current_yield,
    p.current_yield_weight,
    p.cm_vigil,
    p.finalreserve
   FROM import."position" p
  WHERE (p.include = true);


ALTER TABLE import.view_position_include OWNER TO exa_db;

--
-- Name: x5_finance; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.x5_finance (
    cod_banca character varying,
    cod_dossier character varying,
    cod_strumento_finanziario character varying,
    tipo_codifica_strumento_finanz character varying,
    divisa_di_trattazione_suffisso character varying,
    imp_quantita_liquida character varying,
    modello_di_business character varying,
    sub_modello_di_business character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.x5_finance OWNER TO exa_db;

--
-- Name: xm_finance; Type: TABLE; Schema: import; Owner: exa_db
--

CREATE TABLE import.xm_finance (
    cod_banca character varying,
    cod_dossier character varying,
    cod_strumento_finanziario character varying,
    tipo_codifica_strumento_finanz character varying,
    divisa_di_trattazione_suffisso character varying,
    segno character varying,
    imp_quantita character varying,
    modello_di_business character varying,
    sub_modello_di_business character varying,
    cod_causale_cad character varying,
    dat_valuta character varying,
    json jsonb,
    createdon timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE import.xm_finance OWNER TO exa_db;

--
-- Name: apm_file_log; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.apm_file_log (
    import_id bigint NOT NULL,
    rpt_date date NOT NULL,
    file_key character varying(100) NOT NULL,
    archive_uri character varying(1024),
    retry_count integer NOT NULL,
    is_import boolean NOT NULL,
    state_id integer NOT NULL,
    monitor_status public.enum_apm_file_monitor_status,
    content jsonb,
    parent_import_id bigint,
    modified_on timestamp without time zone DEFAULT now() NOT NULL,
    created_on timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.apm_file_log OWNER TO exa_db;

--
-- Name: apm_file_log_import_id_seq; Type: SEQUENCE; Schema: public; Owner: exa_db
--

ALTER TABLE public.apm_file_log ALTER COLUMN import_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.apm_file_log_import_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: apm_import_rec; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.apm_import_rec (
    import_rec_id bigint NOT NULL,
    rec_source_ref character varying(1024),
    file_name character varying(255),
    source character varying(255),
    rpt_date date NOT NULL,
    file_key character varying(100) NOT NULL,
    monitor_status public.enum_apm_import_rec_status,
    retry_count integer NOT NULL,
    content jsonb,
    parent_import_rec_id bigint,
    modified_on timestamp without time zone DEFAULT now() NOT NULL,
    created_on timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.apm_import_rec OWNER TO exa_db;

--
-- Name: apm_import_rec_import_rec_id_seq; Type: SEQUENCE; Schema: public; Owner: exa_db
--

ALTER TABLE public.apm_import_rec ALTER COLUMN import_rec_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.apm_import_rec_import_rec_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: async_jobs; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.async_jobs (
    workflow_id character varying(255) NOT NULL,
    user_id character varying(255) NOT NULL,
    request_body character varying(10000),
    status character varying(15),
    response_details character varying(10000),
    id integer NOT NULL
);


ALTER TABLE public.async_jobs OWNER TO exa_db;

--
-- Name: async_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: exa_db
--

CREATE SEQUENCE public.async_jobs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.async_jobs_id_seq OWNER TO exa_db;

--
-- Name: async_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: exa_db
--

ALTER SEQUENCE public.async_jobs_id_seq OWNED BY public.async_jobs.id;


--
-- Name: bank; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.bank (
    bank_key character varying(100) NOT NULL,
    abi character varying(255),
    city character varying(255),
    code character varying(255),
    created_on timestamp without time zone,
    description character varying(255),
    loc_cust_id character varying(255)
);


ALTER TABLE public.bank OWNER TO exa_db;

--
-- Name: bcp_limit_value; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.bcp_limit_value (
    limit_value_key character varying(255),
    rpt_date date,
    abi character varying(255),
    created_on timestamp without time zone,
    ia_description character varying(255),
    ia_id character varying(255),
    ia_name character varying(255),
    ic_description character varying(255),
    ic_id character varying(255),
    l1max numeric(19,2),
    l1max_perc numeric(19,6),
    l1min numeric(19,2),
    l1min_perc numeric(19,6),
    l2max numeric(19,2),
    l2max_perc numeric(19,6),
    l2min numeric(19,2),
    l2min_perc numeric(19,6),
    limit_display character varying(255),
    limit_key character varying(255),
    max numeric(19,2),
    max_perc numeric(19,6),
    min numeric(19,2),
    min_perc numeric(19,6),
    rl_limit_name character varying(255),
    rp_exceed boolean,
    rp_in_limits character varying(255),
    rp_value numeric(19,2)
);


ALTER TABLE public.bcp_limit_value OWNER TO exa_db;

--
-- Name: position; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public."position" (
    position_type character varying(31) NOT NULL,
    position_key character varying(100) NOT NULL,
    rpt_date date NOT NULL,
    abi character varying(255),
    book character varying(255),
    calc jsonb,
    created_on timestamp without time zone,
    currency character varying(255),
    data jsonb,
    desk character varying(255),
    instrument_key character varying(255),
    isin character varying(255),
    portfolio_key character varying(255),
    quantity numeric(19,4),
    realizedpl numeric(19,4),
    unrealizedpl numeric(19,4),
    exchange character varying(255),
    parent_position_key character varying(100),
    parent_rpt_date date,
    risk_pos_key character varying(100),
    pn numeric(19,4),
    mtm numeric(19,4),
    ytd_margin_interest_accrual numeric(19,4),
    aggiodisaggio numeric(19,4),
    costoammortizzato numeric(19,4),
    initialreserve numeric(19,4),
    current_yield numeric(19,4),
    current_yield_weight numeric(19,4),
    cm_vigil numeric(19,4),
    finalreserve numeric(19,4)
);


ALTER TABLE public."position" OWNER TO exa_db;

--
-- Name: ref_book_config; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_book_config (
    abi character varying(10),
    book character varying(100),
    bps numeric(19,4),
    floor numeric(19,4),
    cap numeric(19,4),
    delega boolean DEFAULT true,
    "from" date,
    "to" date,
    desk character varying(100)
);


ALTER TABLE public.ref_book_config OWNER TO exa_db;

--
-- Name: book; Type: MATERIALIZED VIEW; Schema: public; Owner: exa_db
--

CREATE MATERIALIZED VIEW public.book AS
 SELECT p.rpt_date,
    p.portfolio_key,
    p.abi,
    p.desk,
    p.book,
    p.position_type,
    COALESCE(r.delega, false) AS delega,
    sum(p.quantity) AS quantity,
    sum(p.realizedpl) AS realizedpl,
    sum(p.unrealizedpl) AS unrealizedpl,
    sum(p.pn) AS pn,
    sum(p.mtm) AS mtm,
    sum(p.ytd_margin_interest_accrual) AS ytd_margin_interest_accrual,
    sum(p.aggiodisaggio) AS aggiodisaggio,
    sum(p.costoammortizzato) AS costoammortizzato,
    sum(p.initialreserve) AS initialreserve,
    sum(p.finalreserve) AS finalreserve,
    sum(p.current_yield) AS current_yield,
    sum(p.current_yield_weight) AS current_yield_weight
   FROM (public."position" p
     LEFT JOIN public.ref_book_config r ON ((((p.abi)::text = (r.abi)::text) AND ((p.book)::text = (r.book)::text) AND ((r."from" IS NULL) OR ((r."from" <= p.rpt_date) AND ((r."to" IS NULL) OR (r."to" >= p.rpt_date)))))))
  GROUP BY p.rpt_date, p.portfolio_key, p.abi, p.desk, p.book, p.position_type, COALESCE(r.delega, false)
  WITH NO DATA;


ALTER TABLE public.book OWNER TO exa_db;

--
-- Name: bus_model; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.bus_model (
    position_type character varying(31) NOT NULL,
    position_key character varying(100) NOT NULL,
    bus_model character varying NOT NULL,
    rpt_date date NOT NULL,
    abi character varying(255),
    book character varying(255),
    calc jsonb,
    created_on timestamp without time zone,
    currency character varying(255),
    data jsonb,
    desk character varying(255),
    instrument_key character varying(255),
    isin character varying(255),
    portfolio_key character varying(255),
    quantity numeric(19,4),
    realizedpl numeric(19,4),
    unrealizedpl numeric(19,4),
    exchange character varying(255),
    parent_position_key character varying(100),
    parent_rpt_date date,
    risk_pos_key character varying(100),
    pn numeric(19,4),
    mtm numeric(19,4),
    ytd_margin_interest_accrual numeric(19,4),
    aggiodisaggio numeric(19,4),
    costoammortizzato numeric(19,4),
    initialreserve numeric(19,4),
    finalreserve numeric(19,4),
    current_yield numeric(19,4),
    current_yield_weight numeric(19,4),
    cm_vigil numeric(19,4)
);


ALTER TABLE public.bus_model OWNER TO exa_db;

--
-- Name: cash_flow; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.cash_flow (
    position_key character varying(255) NOT NULL,
    data jsonb,
    rpt_date date
);


ALTER TABLE public.cash_flow OWNER TO exa_db;

--
-- Name: column_def_custom; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.column_def_custom (
    user_id integer,
    preset_code character varying(255) NOT NULL,
    grp character varying(255) NOT NULL,
    json_colums text,
    id_user character varying(255) NOT NULL
);


ALTER TABLE public.column_def_custom OWNER TO exa_db;

--
-- Name: config; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.config (
    key character varying NOT NULL,
    data jsonb NOT NULL,
    config_type character varying NOT NULL
);


ALTER TABLE public.config OWNER TO exa_db;

--
-- Name: finance; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.finance (
    finance_key character varying,
    rpt_date date,
    abi character varying,
    modello_di_business character varying,
    sub_modello_di_business character varying,
    isin character varying,
    x5_quantity numeric(18,4),
    xm_quantity numeric(18,4),
    saldo_summit numeric(18,4),
    difference numeric(18,4),
    saldo_finance numeric(18,4),
    desk character varying,
    book character varying,
    currency character varying,
    status character varying
);


ALTER TABLE public.finance OWNER TO exa_db;

--
-- Name: gdl; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.gdl (
    rpt_date date NOT NULL,
    abi character varying NOT NULL
);


ALTER TABLE public.gdl OWNER TO exa_db;

--
-- Name: hbe_position; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.hbe_position (
    position_key character varying(100) NOT NULL,
    abi character varying(255),
    book character varying(255),
    desk character varying(255),
    isin character varying(255),
    currency character varying(255),
    quantity numeric(19,4),
    realizedpl numeric(19,4),
    data jsonb,
    row_hash character(32),
    starts_on timestamp with time zone NOT NULL,
    ends_on timestamp with time zone,
    deleted boolean
);


ALTER TABLE public.hbe_position OWNER TO exa_db;

--
-- Name: import_error; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.import_error (
    id bigint NOT NULL,
    created_on timestamp without time zone,
    data jsonb,
    entity_type character varying(10),
    error_type character varying(10),
    reason text
);


ALTER TABLE public.import_error OWNER TO exa_db;

--
-- Name: import_error_id_seq; Type: SEQUENCE; Schema: public; Owner: exa_db
--

CREATE SEQUENCE public.import_error_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.import_error_id_seq OWNER TO exa_db;

--
-- Name: import_error_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: exa_db
--

ALTER SEQUENCE public.import_error_id_seq OWNED BY public.import_error.id;


--
-- Name: import_file; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.import_file (
    file_key character varying(50) NOT NULL,
    gsuri character varying(1024) NOT NULL,
    json jsonb NOT NULL,
    created_on timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.import_file OWNER TO exa_db;

--
-- Name: import_log; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.import_log (
    import_id integer NOT NULL,
    rpt_date date NOT NULL,
    file_key character varying(50) NOT NULL,
    archive_uri character varying(1024) NOT NULL,
    file_name character varying(1024) NOT NULL,
    retry_count integer NOT NULL,
    state_id integer NOT NULL,
    modifield_on timestamp without time zone DEFAULT now(),
    created_on timestamp without time zone DEFAULT now()
);


ALTER TABLE public.import_log OWNER TO exa_db;

--
-- Name: import_log_import_id_seq; Type: SEQUENCE; Schema: public; Owner: exa_db
--

CREATE SEQUENCE public.import_log_import_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.import_log_import_id_seq OWNER TO exa_db;

--
-- Name: import_log_import_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: exa_db
--

ALTER SEQUENCE public.import_log_import_id_seq OWNED BY public.import_log.import_id;


--
-- Name: import_test; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.import_test (
    key character varying,
    json jsonb
);


ALTER TABLE public.import_test OWNER TO exa_db;

--
-- Name: instrument; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.instrument (
    instrument_type character varying(31) NOT NULL,
    instrument_key character varying(100) NOT NULL,
    rpt_date date NOT NULL,
    asset_class_key character varying(255),
    country character varying(255),
    created_on timestamp without time zone,
    currency character varying(255),
    description character varying(255),
    isin character varying(12),
    issuer_key character varying(255),
    p_amt_out numeric(19,2),
    p_duration numeric(19,2),
    p_iscoring numeric(19,2),
    p_lotto_minimo numeric(19,2),
    p_price numeric(19,2),
    p_residual_life numeric(19,2),
    p_ytm numeric(19,2),
    price_key character varying(255),
    rating_key integer,
    ratings jsonb,
    sub_type character varying(255),
    type character varying(255),
    calc jsonb,
    data jsonb,
    duration numeric(19,4),
    exchange character varying(255),
    residual_life numeric(19,4),
    ytm numeric(19,4),
    ticker character varying(255)
);


ALTER TABLE public.instrument OWNER TO exa_db;

--
-- Name: instrument_20231102; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.instrument_20231102 (
    instrument_type character varying(31),
    instrument_key character varying(100),
    rpt_date date,
    asset_class_key character varying(255),
    country character varying(255),
    created_on timestamp without time zone,
    currency character varying(255),
    description character varying(255),
    isin character varying(12),
    issuer_key character varying(255),
    p_amt_out numeric(19,2),
    p_duration numeric(19,2),
    p_iscoring numeric(19,2),
    p_lotto_minimo numeric(19,2),
    p_price numeric(19,2),
    p_residual_life numeric(19,2),
    p_ytm numeric(19,2),
    price_key character varying(255),
    rating_key integer,
    ratings jsonb,
    sub_type character varying(255),
    type character varying(255),
    calc jsonb,
    data jsonb,
    duration numeric(19,4),
    exchange character varying(255),
    residual_life numeric(19,4),
    ytm numeric(19,4),
    ticker character varying(255)
);


ALTER TABLE public.instrument_20231102 OWNER TO exa_db;

--
-- Name: limit_dimensional; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.limit_dimensional (
    ptf_type character varying(255) NOT NULL,
    abi character varying(255) NOT NULL,
    dim_limit numeric(19,2),
    life_limit numeric(19,2),
    noteurgroup1 character varying(255),
    noteurgroup1limit numeric(19,2),
    noteurgroup2 character varying(255),
    noteurgroup2limit numeric(19,2),
    noteurgroup3 character varying(255),
    noteurgroup3limit numeric(19,2),
    noteurlimit numeric(19,2),
    noteurother_group_limit numeric(19,2),
    not_quoted_global_limit numeric(19,2),
    not_quoted_gov_limit numeric(19,2),
    not_quoted_not_eligible_bce_limit numeric(19,2),
    not_quoted_other_limit numeric(19,2)
);


ALTER TABLE public.limit_dimensional OWNER TO exa_db;

--
-- Name: limit_dimensional_custom; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.limit_dimensional_custom (
    ptf_type character varying(255) NOT NULL,
    abi character varying(255) NOT NULL,
    dim_limit numeric(19,2),
    life_limit numeric(19,2),
    noteurgroup1 character varying(255),
    noteurgroup1limit numeric(19,2),
    noteurgroup2 character varying(255),
    noteurgroup2limit numeric(19,2),
    noteurgroup3 character varying(255),
    noteurgroup3limit numeric(19,2),
    noteurlimit numeric(19,2),
    noteurother_group_limit numeric(19,2),
    not_quoted_global_limit numeric(19,2),
    not_quoted_gov_limit numeric(19,2),
    not_quoted_not_eligible_bce_limit numeric(19,2),
    not_quoted_other_limit numeric(19,2)
);


ALTER TABLE public.limit_dimensional_custom OWNER TO exa_db;

--
-- Name: limit_value; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.limit_value (
    limit_value_key character varying(255) NOT NULL,
    rpt_date date NOT NULL,
    abi character varying(255),
    created_on timestamp without time zone,
    ia_description character varying(255),
    ia_id character varying(255),
    ia_name character varying(255),
    ic_description character varying(255),
    ic_id character varying(255),
    l1max numeric(19,2),
    l1max_perc numeric(19,6),
    l1min numeric(19,2),
    l1min_perc numeric(19,6),
    l2max numeric(19,2),
    l2max_perc numeric(19,6),
    l2min numeric(19,2),
    l2min_perc numeric(19,6),
    limit_display character varying(255),
    limit_key character varying(255),
    max numeric(19,2),
    max_perc numeric(19,6),
    min numeric(19,2),
    min_perc numeric(19,6),
    rl_limit_name character varying(255),
    rp_exceed boolean,
    rp_in_limits character varying(255),
    rp_value numeric(19,6),
    perc_max numeric(19,2),
    perc_min numeric(19,2),
    reference_date date
);


ALTER TABLE public.limit_value OWNER TO exa_db;

--
-- Name: limits_perc; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.limits_perc (
    limit_key character varying(100) NOT NULL,
    abi character varying(255),
    asset_class character varying(255),
    desk character varying(255),
    global boolean,
    max numeric(19,2),
    min numeric(19,2),
    perc_max numeric(19,2),
    perc_min numeric(19,2),
    rating_class character varying(255)
);


ALTER TABLE public.limits_perc OWNER TO exa_db;

--
-- Name: margin_hs; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.margin_hs (
    id integer NOT NULL,
    cash_flow_date timestamp without time zone,
    discount_eonia numeric(19,2),
    discount_eur6m numeric(19,2),
    evaluation_date timestamp without time zone,
    isin character varying(255),
    payment numeric(19,2),
    perc_discount_eonia numeric(19,2),
    perc_discount_eur6m numeric(19,2),
    portfolio_id integer
);


ALTER TABLE public.margin_hs OWNER TO exa_db;

--
-- Name: morningstar_category; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.morningstar_category (
    morningstar_category_key character varying(100) NOT NULL,
    as_type_code_id integer,
    definition character varying(255),
    definition_italian character varying(255),
    type_code character varying(255),
    type_code_group character varying(255)
);


ALTER TABLE public.morningstar_category OWNER TO exa_db;

--
-- Name: ref_apm_file_key; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_apm_file_key (
    file_key character varying(100) NOT NULL,
    file_key_desc character varying(100) NOT NULL,
    file_regex character varying(200) NOT NULL,
    source public.enum_apm_file_key_source NOT NULL,
    active_flag boolean NOT NULL,
    monitor_flag boolean NOT NULL,
    location_name_flag boolean NOT NULL,
    archive_flag boolean NOT NULL,
    expected_count integer,
    content jsonb,
    modified_on timestamp with time zone DEFAULT now(),
    created_on timestamp with time zone DEFAULT now(),
    rpt_date_flag boolean DEFAULT false,
    sort integer DEFAULT 0 NOT NULL
);


ALTER TABLE public.ref_apm_file_key OWNER TO exa_db;

--
-- Name: ref_apm_file_loc; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_apm_file_loc (
    location_name character varying(100) NOT NULL,
    abi character(5),
    is_bank boolean,
    modified_on timestamp with time zone DEFAULT now(),
    created_on timestamp with time zone DEFAULT now()
);


ALTER TABLE public.ref_apm_file_loc OWNER TO exa_db;

--
-- Name: mview_file_loc; Type: MATERIALIZED VIEW; Schema: public; Owner: exa_db
--

CREATE MATERIALIZED VIEW public.mview_file_loc AS
 SELECT k.file_key,
    k.file_key_desc,
    l.location_name
   FROM public.ref_apm_file_key k,
    public.ref_apm_file_loc l
  WHERE ((k.active_flag = true) AND (k.monitor_flag = true) AND (k.location_name_flag = true))
  WITH NO DATA;


ALTER TABLE public.mview_file_loc OWNER TO exa_db;

--
-- Name: part_order_test; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.part_order_test (
    rpt_date integer NOT NULL,
    abi character(10) NOT NULL,
    description character varying(100),
    created_on timestamp without time zone DEFAULT CURRENT_DATE
)
PARTITION BY RANGE (rpt_date);


ALTER TABLE public.part_order_test OWNER TO exa_db;

--
-- Name: permission; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.permission (
    id integer NOT NULL,
    code character varying(255) NOT NULL,
    description character varying(255)
);


ALTER TABLE public.permission OWNER TO exa_db;

--
-- Name: portfolio; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.portfolio (
    portfolio_key character varying(100) NOT NULL,
    abi character varying(255),
    desk character varying(255)
);


ALTER TABLE public.portfolio OWNER TO exa_db;

--
-- Name: portfolio_info; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.portfolio_info (
    portfolioinfo_key character varying NOT NULL,
    rpt_date date NOT NULL,
    abi character varying NOT NULL,
    cash_balance numeric(18,4) NOT NULL,
    data_regolamento date NOT NULL,
    data jsonb
);


ALTER TABLE public.portfolio_info OWNER TO exa_db;

--
-- Name: pos_tmp; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.pos_tmp (
    position_type character varying,
    position_key character varying,
    rpt_date date,
    abi character varying,
    book character varying,
    calc jsonb,
    created_on timestamp without time zone,
    currency text,
    data jsonb,
    desk character varying,
    instrument_key character varying,
    isin character varying,
    portfolio_key character varying,
    quantity numeric,
    realizedpl double precision,
    unrealizedpl numeric,
    exchange character varying,
    parent_position_key character varying,
    parent_rpt_date date,
    risk_pos_key character varying,
    subtype character varying,
    pn numeric,
    mtm numeric,
    description character varying,
    residual_life numeric,
    ytdmargininterestaccrual numeric,
    aggiodisaggio numeric,
    costoammortizzato numeric,
    finalreserve numeric,
    current_yield numeric,
    current_yield_weight numeric,
    cmvigil numeric,
    asset_class_key character varying
);


ALTER TABLE public.pos_tmp OWNER TO exa_db;

--
-- Name: position_20231102; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.position_20231102 (
    position_type character varying(31),
    position_key character varying(100),
    rpt_date date,
    abi character varying(255),
    book character varying(255),
    calc jsonb,
    created_on timestamp without time zone,
    currency character varying(255),
    data jsonb,
    desk character varying(255),
    instrument_key character varying(255),
    isin character varying(255),
    portfolio_key character varying(255),
    quantity numeric(19,4),
    realizedpl numeric(19,4),
    unrealizedpl numeric(19,4),
    exchange character varying(255),
    parent_position_key character varying(100),
    parent_rpt_date date,
    risk_pos_key character varying(100),
    pn numeric(19,4),
    mtm numeric(19,4),
    ytd_margin_interest_accrual numeric(19,4),
    aggiodisaggio numeric(19,4),
    costoammortizzato numeric(19,4),
    initialreserve numeric(19,4),
    current_yield numeric(19,4),
    current_yield_weight numeric(19,4),
    cm_vigil numeric(19,4),
    finalreserve numeric(19,4)
);


ALTER TABLE public.position_20231102 OWNER TO exa_db;

--
-- Name: position_link_rule; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.position_link_rule (
    origin character varying(255) NOT NULL,
    type character varying(255) NOT NULL,
    destination character varying(255)
);


ALTER TABLE public.position_link_rule OWNER TO exa_db;

--
-- Name: position_monitor; Type: VIEW; Schema: public; Owner: exa_db
--

CREATE VIEW public.position_monitor AS
 SELECT "position".position_key AS grouping_key,
    "position".position_type,
    "position".position_key,
    "position".rpt_date,
    "position".abi,
    "position".book,
    (array_to_json(ARRAY["position".calc]))::jsonb AS calc_list,
    "position".created_on,
    "position".currency,
    (array_to_json(ARRAY["position".data]))::jsonb AS data_list,
    "position".desk,
    "position".instrument_key,
    "position".isin,
    "position".portfolio_key,
    "position".quantity,
    (("position".data ->> 'ytdrealizedPL'::text))::double precision AS realizedpl,
    "position".unrealizedpl,
    "position".exchange,
    "position".parent_position_key,
    "position".parent_rpt_date
   FROM public."position"
  WHERE (("position".position_type)::text = 'BOND'::text)
UNION
 SELECT concat((max(ARRAY["position".parent_position_key]))[1], '_SWAP') AS grouping_key,
    "position".position_type,
    "left"(((max(ARRAY["position".position_key]))[1])::text, (length(((max(ARRAY["position".position_key]))[1])::text) - 4)) AS position_key,
    "position".rpt_date,
    "position".abi,
    "position".book,
    (json_strip_nulls(json_agg(json_build_object('type', ("position".calc ->> 'type'::text), 'costoAmmortizzato', ("position".calc ->> 'costoAmmortizzato'::text), 'legId', ("position".data ->> 'legId'::text)))))::jsonb AS calc_list,
    (max(ARRAY["position".created_on]))[1] AS created_on,
    "position".currency,
    (json_strip_nulls(json_agg("position".data)))::jsonb AS data_list,
    "position".desk,
    "position".instrument_key,
    "position".isin,
    "position".portfolio_key,
    abs((max(ARRAY["position".quantity]) FILTER (WHERE (("position".data ->> 'legId'::text) = 'P'::text)))[1]) AS quantity,
    sum((("position".data ->> 'capGL'::text))::double precision) AS realizedpl,
    sum((("position".data ->> 'remMktVal'::text))::double precision) AS unrealizedpl,
    "position".exchange,
    (max(ARRAY["position".parent_position_key]))[1] AS parent_position_key,
    (max(ARRAY["position".parent_rpt_date]))[1] AS parent_rpt_date
   FROM public."position"
  WHERE (("position".position_type)::text = 'SWAP'::text)
  GROUP BY "position".position_type, "position".rpt_date, "position".abi, "position".book, "position".desk, "position".instrument_key, "position".currency, "position".isin, "position".portfolio_key, "position".exchange;


ALTER TABLE public.position_monitor OWNER TO exa_db;

--
-- Name: position_predeal; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.position_predeal (
    position_key character varying(100) NOT NULL,
    abi character varying(255),
    book character varying(255),
    currency character varying(255),
    desk character varying(255),
    exchange character varying(255),
    instrument_key character varying(255),
    isin character varying(255),
    portfolio_key character varying(255),
    predeal_key integer NOT NULL,
    price numeric(19,2),
    quantity numeric(19,4),
    sign integer,
    data jsonb,
    rpt_date timestamp without time zone
);


ALTER TABLE public.position_predeal OWNER TO exa_db;

--
-- Name: predeal; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.predeal (
    id integer NOT NULL,
    created_on timestamp without time zone,
    modified_on timestamp without time zone,
    name character varying(255),
    portfolio_key character varying(255),
    rpt_date date,
    owner_predeal integer,
    owner character varying(255) NOT NULL
);


ALTER TABLE public.predeal OWNER TO exa_db;

--
-- Name: predeal_id_seq; Type: SEQUENCE; Schema: public; Owner: exa_db
--

CREATE SEQUENCE public.predeal_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.predeal_id_seq OWNER TO exa_db;

--
-- Name: predeal_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: exa_db
--

ALTER SEQUENCE public.predeal_id_seq OWNED BY public.predeal.id;


--
-- Name: price; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.price (
    price_key character varying(100) NOT NULL,
    exchange character varying(255),
    isin character varying(12),
    last_updated timestamp without time zone,
    price numeric(19,4) NOT NULL
);


ALTER TABLE public.price OWNER TO exa_db;

--
-- Name: profile; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.profile (
    code character varying(20) NOT NULL,
    description character varying(100),
    view_all_abi boolean DEFAULT false
);


ALTER TABLE public.profile OWNER TO exa_db;

--
-- Name: profile_has_permission; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.profile_has_permission (
    profile_code character varying(20) NOT NULL,
    permission_code character varying(100) NOT NULL
);


ALTER TABLE public.profile_has_permission OWNER TO exa_db;

--
-- Name: ref_apm_file; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_apm_file (
    file_key character varying(100) NOT NULL,
    file_regex character varying(150) NOT NULL,
    source character varying(20) NOT NULL,
    active_flag boolean,
    monitor_flag boolean,
    archive_flag boolean,
    expected_count integer,
    content jsonb,
    modified_on timestamp with time zone DEFAULT now(),
    created_on timestamp with time zone DEFAULT now(),
    location_name_flag boolean DEFAULT false
);


ALTER TABLE public.ref_apm_file OWNER TO exa_db;

--
-- Name: ref_city_to_region; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_city_to_region (
    city character varying(255) NOT NULL,
    region character varying(255)
);


ALTER TABLE public.ref_city_to_region OWNER TO exa_db;

--
-- Name: ref_issuer; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_issuer (
    issuer_key character varying(100) NOT NULL,
    code character varying(255),
    description character varying(255)
);


ALTER TABLE public.ref_issuer OWNER TO exa_db;

--
-- Name: ref_limit; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_limit (
    limit_key character varying(255) NOT NULL,
    abi character varying(255),
    asset_class_key character varying(255),
    attribute_class_key character varying(255),
    desk character varying(255),
    global boolean,
    ic_id character varying(255),
    limit_description character varying(255),
    limit_keyl1 character varying(255),
    limit_keyl2 character varying(255),
    type_desc character varying(255),
    asset_class character varying(255),
    category character varying(255),
    note character varying(255),
    rating_class character varying(255),
    parent_id character varying(255),
    rl_limit_name character varying(20)
);


ALTER TABLE public.ref_limit OWNER TO exa_db;

--
-- Name: ref_limit_asset_class; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_limit_asset_class (
    value character varying(255) NOT NULL,
    asset_class_key character varying(255) NOT NULL
);


ALTER TABLE public.ref_limit_asset_class OWNER TO exa_db;

--
-- Name: ref_limit_attribute_class; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_limit_attribute_class (
    value character varying(255) NOT NULL,
    type character varying(255) NOT NULL,
    attribute_class_key character varying(255) NOT NULL
);


ALTER TABLE public.ref_limit_attribute_class OWNER TO exa_db;

--
-- Name: ref_range; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_range (
    code character varying(15) NOT NULL,
    min numeric,
    max numeric NOT NULL,
    description character varying(15)
);


ALTER TABLE public.ref_range OWNER TO exa_db;

--
-- Name: ref_rating; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_rating (
    rating_key integer NOT NULL,
    classe_merito character varying(255),
    cn_sensus character varying(255),
    fitch character varying(255),
    iscoring character varying(255),
    mdy character varying(255),
    ord integer,
    score character varying(255),
    sep character varying(255)
);


ALTER TABLE public.ref_rating OWNER TO exa_db;

--
-- Name: ref_rpt_date; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_rpt_date (
    rpt_date date NOT NULL,
    display_date date,
    business_day boolean,
    prev_business_date date,
    next_business_date date,
    state_id integer,
    create_on timestamp without time zone DEFAULT LOCALTIMESTAMP,
    business_date boolean,
    modified_on timestamp without time zone DEFAULT LOCALTIMESTAMP,
    done_on timestamp without time zone
);


ALTER TABLE public.ref_rpt_date OWNER TO exa_db;

--
-- Name: ref_state; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.ref_state (
    state_id integer NOT NULL,
    state character varying(255),
    category character varying(50),
    used_by character varying(255)[],
    created_on timestamp without time zone DEFAULT CURRENT_DATE,
    state_transition integer[]
);


ALTER TABLE public.ref_state OWNER TO exa_db;

--
-- Name: report; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.report (
    code character varying(255) NOT NULL
);


ALTER TABLE public.report OWNER TO exa_db;

--
-- Name: risk_market_data; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.risk_market_data (
    risk_market_data_key character varying(100) NOT NULL,
    rpt_date date NOT NULL,
    currency character varying(255),
    date date,
    index_name character varying(255),
    maturity date,
    rate numeric(19,6),
    term character varying(255),
    type character varying(255)
);


ALTER TABLE public.risk_market_data OWNER TO exa_db;

--
-- Name: risk_market_data_fixing; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.risk_market_data_fixing (
    date date NOT NULL,
    risk_market_data_fixing_key character varying(100) NOT NULL,
    currency character varying(255),
    index_name character varying(255),
    maturity date,
    rate numeric(19,6),
    term character varying(255),
    type character varying(255)
);


ALTER TABLE public.risk_market_data_fixing OWNER TO exa_db;

--
-- Name: risk_market_data_fixing_20231102; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.risk_market_data_fixing_20231102 (
    date date,
    risk_market_data_fixing_key character varying(100),
    currency character varying(255),
    index_name character varying(255),
    maturity date,
    rate numeric(19,5),
    term character varying(255),
    type character varying(255)
);


ALTER TABLE public.risk_market_data_fixing_20231102 OWNER TO exa_db;

--
-- Name: risk_pos; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.risk_pos (
    risk_pos_key character varying(100) NOT NULL,
    rpt_date date NOT NULL,
    cr01 numeric(19,2),
    es numeric(19,2),
    il01 numeric(19,2),
    ir01 numeric(19,2),
    isin_code character varying(255),
    ivar numeric(19,2),
    mvar numeric(19,2),
    var_1d numeric(19,2),
    abi character varying(255),
    amount_eur numeric(19,2),
    asset_code character varying(255),
    description character varying(255),
    desk character varying(255),
    pid character varying(255),
    portfolio_key character varying(255),
    reference_date date,
    weight numeric(19,2),
    mtm numeric(19,4)
);


ALTER TABLE public.risk_pos OWNER TO exa_db;

--
-- Name: risk_ptf; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.risk_ptf (
    risk_ptf_key character varying(100) NOT NULL,
    rpt_date date NOT NULL,
    aggregation_name character varying(255),
    es numeric(19,2),
    ivar numeric(19,2),
    mvar numeric(19,2),
    var_1d numeric(19,2),
    abi character varying(255),
    desk character varying(255),
    portfolio_key character varying(255),
    reference_date date,
    cr01 numeric(19,4),
    il01 numeric(19,4),
    ir01 numeric(19,4)
);


ALTER TABLE public.risk_ptf OWNER TO exa_db;

--
-- Name: role; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.role (
    id integer NOT NULL,
    description character varying(255),
    title character varying(255) NOT NULL
);


ALTER TABLE public.role OWNER TO exa_db;

--
-- Name: role_has_permission; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.role_has_permission (
    role_id integer NOT NULL,
    permission_id integer NOT NULL
);


ALTER TABLE public.role_has_permission OWNER TO exa_db;

--
-- Name: rpt_position; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.rpt_position (
    rpt_date date NOT NULL,
    position_key character varying(100) NOT NULL,
    starts_on timestamp with time zone NOT NULL
);


ALTER TABLE public.rpt_position OWNER TO exa_db;

--
-- Name: sector; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.sector (
    code character varying(255) NOT NULL,
    description character varying(255)
);


ALTER TABLE public.sector OWNER TO exa_db;

--
-- Name: sensitivity; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.sensitivity (
    abi character varying,
    desk character varying,
    risk_cluster character varying,
    term_days integer,
    original_bucket character varying,
    name character varying,
    ir01_eur numeric(19,4),
    cr01_eur numeric(19,4),
    il01_eur numeric(19,4),
    ir01_usd numeric(19,4),
    cr01_usd numeric(19,4),
    il01_usd numeric(19,4),
    ir01_gbp numeric(19,4),
    cr01_gbp numeric(19,4),
    il01_gbp numeric(19,4),
    rpt_date date NOT NULL,
    sensitivity_key uuid DEFAULT gen_random_uuid() NOT NULL
);


ALTER TABLE public.sensitivity OWNER TO exa_db;

--
-- Name: temp_20230709_apm_file_log; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.temp_20230709_apm_file_log (
    import_id bigint,
    rpt_date date,
    file_key character varying(100),
    archive_uri character varying(1024),
    retry_count integer,
    is_import boolean,
    state_id integer,
    monitor_status public.enum_apm_file_monitor_status,
    content jsonb,
    parent_import_id bigint,
    modified_on timestamp without time zone,
    created_on timestamp without time zone
);


ALTER TABLE public.temp_20230709_apm_file_log OWNER TO exa_db;

--
-- Name: temp_apm_file_log_20230626; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.temp_apm_file_log_20230626 (
    import_id bigint,
    rpt_date date,
    file_key character varying(100),
    file_rpt_date date,
    archive_uri character varying(1024),
    file_name character varying(1024),
    retry_count integer,
    state_id integer,
    modified_on timestamp without time zone,
    created_on timestamp without time zone
);


ALTER TABLE public.temp_apm_file_log_20230626 OWNER TO exa_db;

--
-- Name: temp_prod_instrument; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.temp_prod_instrument (
    instrument_type character varying(31) NOT NULL,
    instrument_key character varying(100) NOT NULL,
    rpt_date date NOT NULL,
    asset_class_key character varying(255),
    country character varying(255),
    created_on timestamp without time zone,
    currency character varying(255),
    description character varying(255),
    isin character varying(12),
    issuer_key character varying(255),
    p_amt_out numeric(19,2),
    p_duration numeric(19,2),
    p_iscoring numeric(19,2),
    p_lotto_minimo numeric(19,2),
    p_price numeric(19,2),
    p_residual_life numeric(19,2),
    p_ytm numeric(19,2),
    price_key character varying(255),
    rating_key integer,
    ratings jsonb,
    sub_type character varying(255),
    type character varying(255),
    calc jsonb,
    data jsonb,
    duration numeric(19,4),
    exchange character varying(255),
    residual_life numeric(19,4),
    ytm numeric(19,4),
    ticker character varying(255)
);


ALTER TABLE public.temp_prod_instrument OWNER TO exa_db;

--
-- Name: temp_prod_ref_issuer; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.temp_prod_ref_issuer (
    issuer_key character varying(100) NOT NULL,
    code character varying(255),
    description character varying(255)
);


ALTER TABLE public.temp_prod_ref_issuer OWNER TO exa_db;

--
-- Name: template; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.template (
    id integer NOT NULL,
    code character varying(255),
    description character varying(255),
    html text
);


ALTER TABLE public.template OWNER TO exa_db;

--
-- Name: tmp_issue; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.tmp_issue (
    issuer_key character varying(100),
    code character varying(255),
    description character varying(255)
);


ALTER TABLE public.tmp_issue OWNER TO exa_db;

--
-- Name: trade; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.trade (
    rpt_date date NOT NULL,
    trade_key character varying(100) NOT NULL,
    starts_on timestamp without time zone NOT NULL
);


ALTER TABLE public.trade OWNER TO exa_db;

--
-- Name: trade_hist; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.trade_hist (
    trade_key character varying(100) NOT NULL,
    abi character varying(255),
    book character varying(255),
    desk character varying(255),
    isin character varying(255),
    notional numeric(19,4),
    clean_price numeric(19,4),
    trade_status character varying(255),
    trade_entry_date date,
    settle_date date,
    ext_trade_id character varying(255),
    trade_date date,
    pors character varying(255),
    company character varying(255),
    row_hash character varying(255),
    starts_on timestamp without time zone NOT NULL,
    ends_on timestamp without time zone,
    deleted boolean,
    execution_datetime timestamp without time zone
);


ALTER TABLE public.trade_hist OWNER TO exa_db;

--
-- Name: trade_hist_tmp_20231205; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.trade_hist_tmp_20231205 (
    trade_key character varying(100),
    abi character varying(255),
    book character varying(255),
    desk character varying(255),
    isin character varying(255),
    notional numeric(19,4),
    clean_price numeric(19,4),
    trade_status character varying(255),
    trade_entry_date date,
    settle_date date,
    ext_trade_id character varying(255),
    trade_date date,
    pors character varying(255),
    company character varying(255),
    row_hash character varying(255),
    starts_on timestamp without time zone,
    ends_on timestamp without time zone,
    deleted boolean,
    execution_datetime timestamp without time zone
);


ALTER TABLE public.trade_hist_tmp_20231205 OWNER TO exa_db;

--
-- Name: trade_reconciliation; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.trade_reconciliation (
    trade_reconciliation_key character varying NOT NULL,
    isin character varying,
    desk character varying,
    book character varying,
    abi character varying,
    trade_quantity numeric(18,4),
    position_quantity numeric(18,4),
    rpt_date date NOT NULL,
    status character varying,
    trade_key character varying
);


ALTER TABLE public.trade_reconciliation OWNER TO exa_db;

--
-- Name: user_credential; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.user_credential (
    id integer NOT NULL,
    app_id character varying(255),
    enabled boolean NOT NULL,
    password character varying(255),
    username character varying(255) NOT NULL
);


ALTER TABLE public.user_credential OWNER TO exa_db;

--
-- Name: user_has_role; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.user_has_role (
    user_id integer NOT NULL,
    role_id integer NOT NULL
);


ALTER TABLE public.user_has_role OWNER TO exa_db;

--
-- Name: user_permission; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.user_permission (
    code character varying(100) NOT NULL,
    description character varying(100)
);


ALTER TABLE public.user_permission OWNER TO exa_db;

--
-- Name: user_profile; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.user_profile (
    id integer NOT NULL,
    accept_privacy boolean,
    accept_terms boolean,
    company character varying(255),
    email character varying(255),
    first_name character varying(255),
    last_name character varying(255),
    user_id integer
);


ALTER TABLE public.user_profile OWNER TO exa_db;

--
-- Name: v_now; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.v_now (
    "current_timestamp" timestamp with time zone
);


ALTER TABLE public.v_now OWNER TO exa_db;

--
-- Name: verification_token; Type: TABLE; Schema: public; Owner: exa_db
--

CREATE TABLE public.verification_token (
    id integer NOT NULL,
    app_id character varying(255),
    confirm_date timestamp without time zone,
    expiry_date timestamp without time zone,
    registration_url character varying(255),
    token character varying(255),
    verify_url character varying(255),
    user_id integer NOT NULL
);


ALTER TABLE public.verification_token OWNER TO exa_db;

--
-- Name: view_limit_value; Type: VIEW; Schema: public; Owner: exa_db
--

CREATE VIEW public.view_limit_value AS
 SELECT v.limit_value_key,
    v.abi,
    l.desk,
    l.global,
    l.asset_class_key,
    l.attribute_class_key,
    v.max,
    v.max_perc,
    v.l1max,
    v.l1max_perc,
    v.l2max,
    v.l2max_perc,
    v.min,
    v.min_perc,
    v.l1min,
    v.l1min_perc,
    v.l2min,
    v.l2min_perc,
    v.ia_name,
    v.ia_description,
    v.ic_description,
    v.rpt_date,
    v.rp_exceed,
    v.limit_display,
    v.rp_value,
    v.reference_date,
    v.ia_id
   FROM (public.ref_limit l
     JOIN public.limit_value v ON ((((l.limit_key)::text = (v.limit_key)::text) AND ((v.abi)::text = (
        CASE
            WHEN ((l.abi)::text <> 'ALL'::text) THEN l.abi
            ELSE v.abi
        END)::text))));


ALTER TABLE public.view_limit_value OWNER TO exa_db;

--
-- Name: view_position; Type: VIEW; Schema: public; Owner: exa_db
--

CREATE VIEW public.view_position AS
 WITH pos AS (
         SELECT "position".risk_pos_key,
            "position".position_type,
            "position".position_key,
            "position".rpt_date,
            "position".abi,
            "position".book,
            "position".calc,
            "position".created_on,
            'EUR'::text AS currency,
            "position".data,
            "position".desk,
            "position".instrument_key,
            "position".isin,
            "position".portfolio_key,
            "position".quantity,
            (("position".data ->> 'ytdrealizedPL'::text))::double precision AS realizedpl,
            "position".unrealizedpl,
            "position".exchange,
            "position".parent_position_key,
            "position".parent_rpt_date,
            (COALESCE((("position".data ->> 'mktPrice'::text))::numeric, (0)::numeric) * COALESCE("position".quantity, (0)::numeric)) AS pn,
            "position".isin AS description,
            NULL::numeric AS residual_life
           FROM public."position"
          WHERE (("position".position_type)::text = 'EQUITY'::text)
        UNION
         SELECT b.risk_pos_key,
            b.position_type,
            b.position_key,
            b.rpt_date,
            b.abi,
            b.book,
            b.calc,
            b.created_on,
            'EUR'::text AS currency,
            b.data,
            b.desk,
            b.instrument_key,
            b.isin,
            b.portfolio_key,
            b.quantity,
            ((b.data ->> 'ytdrealizedPL'::text))::double precision AS realizedpl,
            b.unrealizedpl,
            b.exchange,
            b.parent_position_key,
            b.parent_rpt_date,
                CASE
                    WHEN ((b.book)::text = ANY ((ARRAY['STRATEGICO'::character varying, 'D_HTC_CA'::character varying, 'D_D_HDG_HTC'::character varying, 'D_HTC_FVTPL'::character varying, 'D_HTCS_FVOCI'::character varying, 'D_D_HDG_HTCS'::character varying, 'D_HTCS_FVTPL'::character varying])::text[])) THEN ((COALESCE(((b.calc ->> 'pmc'::text))::numeric, (0)::numeric) * b.quantity) / (100)::numeric)
                    ELSE (COALESCE(((b.data ->> 'mtMPrezzoSecco'::text))::numeric, (0)::numeric) + COALESCE(((b.calc ->> 'interestAccrual'::text))::numeric, (0)::numeric))
                END AS pn,
            (NULLIF((i.description)::text, (i.isin)::text))::character varying(255) AS description,
            i.residual_life
           FROM (public."position" b
             JOIN public.instrument i ON ((((b.instrument_key)::text = (i.instrument_key)::text) AND (b.rpt_date = i.rpt_date))))
          WHERE ((b.position_type)::text = 'BOND'::text)
        UNION
         SELECT "position".risk_pos_key,
            "position".position_type,
            "left"(((max(ARRAY["position".position_key]))[1])::text, (length(((max(ARRAY["position".position_key]))[1])::text) - 4)) AS position_key,
            "position".rpt_date,
            "position".abi,
            "position".book,
            (json_build_object('type', (max(ARRAY[("position".calc ->> 'type'::text)]))[1], 'legs', json_strip_nulls(json_agg(json_build_object('costoAmmortizzato', ("position".calc ->> 'costoAmmortizzato'::text), 'legId', ("position".data ->> 'legId'::text), 'eir', ("position".calc ->> 'eir'::text))))))::jsonb AS calc,
            (max(ARRAY["position".created_on]))[1] AS created_on,
            'EUR'::text AS currency,
            (json_build_object('type', (max(ARRAY[("position".data ->> 'type'::text)]))[1], 'legs', json_strip_nulls(json_agg(("position".data - 'type'::text)))))::jsonb AS data,
            "position".desk,
            "position".instrument_key,
            "position".isin,
            "position".portfolio_key,
            abs((max(ARRAY["position".quantity]) FILTER (WHERE (("position".data ->> 'legId'::text) = 'P'::text)))[1]) AS quantity,
            sum("position".realizedpl) AS realizedpl,
            sum("position".unrealizedpl) AS unrealizedpl,
            "position".exchange,
            (max(ARRAY["position".parent_position_key]))[1] AS parent_position_key,
            (max(ARRAY["position".parent_rpt_date]))[1] AS parent_rpt_date,
            sum(((("position".data ->> 'remMktVal'::text))::numeric + (("position".data ->> 'remAccrInt'::text))::numeric)) AS pn,
            "position".isin AS description,
            NULL::numeric AS residual_life
           FROM public."position"
          WHERE (("position".position_type)::text = 'SWAP'::text)
          GROUP BY "position".risk_pos_key, "position".position_type, "position".rpt_date, "position".abi, "position".book, "position".desk, "position".instrument_key, "position".isin, "position".portfolio_key, "position".exchange
        )
 SELECT pos.risk_pos_key,
    pos.position_type,
    pos.position_key,
    pos.rpt_date,
    pos.abi,
    pos.book,
    pos.calc,
    pos.created_on,
    pos.currency,
    pos.data,
    pos.desk,
    pos.instrument_key,
    pos.isin,
    pos.portfolio_key,
    pos.quantity,
    pos.realizedpl,
    pos.unrealizedpl,
    pos.exchange,
    pos.parent_position_key,
    pos.parent_rpt_date,
    pos.pn,
    pos.description,
    pos.residual_life
   FROM pos;


ALTER TABLE public.view_position OWNER TO exa_db;

--
-- Name: view_position_limited_isin; Type: VIEW; Schema: public; Owner: exa_db
--

CREATE VIEW public.view_position_limited_isin AS
 SELECT "position".position_key,
    "position".rpt_date,
    "position".abi,
    "position".book,
    "position".desk,
    "position".isin,
    "position".currency,
    "position".quantity,
    "position".realizedpl,
    "position".data,
    md5((ROW("position".abi, "position".book, "position".desk, "position".isin, "position".currency, "position".quantity, "position".realizedpl, "position".data))::text) AS row_hash
   FROM public."position"
  WHERE (("position".isin)::text = ANY ((ARRAY['IT0005174906'::character varying, 'IT0005177909'::character varying, 'IT0005215246'::character varying, 'IT0005217770'::character varying, 'IT0005383309'::character varying, 'IT0005383309'::character varying, 'IT0005424251'::character varying, 'IT0005425761'::character varying, 'IT0005445306'::character varying, 'IT0005451361'::character varying])::text[]));


ALTER TABLE public.view_position_limited_isin OWNER TO exa_db;

--
-- Name: ref_cod_causale_cad id; Type: DEFAULT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.ref_cod_causale_cad ALTER COLUMN id SET DEFAULT nextval('import.ref_cod_causale_cad_id_seq'::regclass);


--
-- Name: test_jwrite_main id; Type: DEFAULT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.test_jwrite_main ALTER COLUMN id SET DEFAULT nextval('import.test_jwrite_main_id_seq'::regclass);


--
-- Name: async_jobs id; Type: DEFAULT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.async_jobs ALTER COLUMN id SET DEFAULT nextval('public.async_jobs_id_seq'::regclass);


--
-- Name: import_error id; Type: DEFAULT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.import_error ALTER COLUMN id SET DEFAULT nextval('public.import_error_id_seq'::regclass);


--
-- Name: import_log import_id; Type: DEFAULT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.import_log ALTER COLUMN import_id SET DEFAULT nextval('public.import_log_import_id_seq'::regclass);


--
-- Name: predeal id; Type: DEFAULT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.predeal ALTER COLUMN id SET DEFAULT nextval('public.predeal_id_seq'::regclass);


--
-- Name: bus_model bus_model_pkey; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.bus_model
    ADD CONSTRAINT bus_model_pkey PRIMARY KEY (position_key, rpt_date);


--
-- Name: eefgbci_bond eefgbci_bond_pk; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.eefgbci_bond
    ADD CONSTRAINT eefgbci_bond_pk PRIMARY KEY (eefgbci_bond_key);


--
-- Name: gdl gdl_pk; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.gdl
    ADD CONSTRAINT gdl_pk PRIMARY KEY (rpt_date, abi);


--
-- Name: instrument instrument_pkey; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.instrument
    ADD CONSTRAINT instrument_pkey PRIMARY KEY (instrument_key, rpt_date);


--
-- Name: limit_value limit_value_pkey; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.limit_value
    ADD CONSTRAINT limit_value_pkey PRIMARY KEY (limit_value_key, rpt_date);


--
-- Name: position position_pkey; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import."position"
    ADD CONSTRAINT position_pkey PRIMARY KEY (position_key, rpt_date);


--
-- Name: risk_market_data risk_market_data_pkey; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.risk_market_data
    ADD CONSTRAINT risk_market_data_pkey PRIMARY KEY (risk_market_data_key, rpt_date);


--
-- Name: risk_pos risk_pos_pkey; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.risk_pos
    ADD CONSTRAINT risk_pos_pkey PRIMARY KEY (risk_pos_key, rpt_date);


--
-- Name: risk_ptf risk_ptf_pkey; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.risk_ptf
    ADD CONSTRAINT risk_ptf_pkey PRIMARY KEY (risk_ptf_key, rpt_date);


--
-- Name: test_jwrite_city test_jwrite_city_pkey; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.test_jwrite_city
    ADD CONSTRAINT test_jwrite_city_pkey PRIMARY KEY (city_key);


--
-- Name: test_jwrite_main test_jwrite_main_pkey; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.test_jwrite_main
    ADD CONSTRAINT test_jwrite_main_pkey PRIMARY KEY (id);


--
-- Name: trade trade_pk; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.trade
    ADD CONSTRAINT trade_pk PRIMARY KEY (rpt_date, trade_key);


--
-- Name: trade_reconciliation trade_reconciliation_pk; Type: CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.trade_reconciliation
    ADD CONSTRAINT trade_reconciliation_pk PRIMARY KEY (trade_reconciliation_key, rpt_date);


--
-- Name: apm_file_log apm_file_log_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.apm_file_log
    ADD CONSTRAINT apm_file_log_pkey PRIMARY KEY (import_id);


--
-- Name: apm_import_rec apm_import_rec_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.apm_import_rec
    ADD CONSTRAINT apm_import_rec_pkey PRIMARY KEY (import_rec_id);


--
-- Name: async_jobs async_jobs_pk; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.async_jobs
    ADD CONSTRAINT async_jobs_pk PRIMARY KEY (id);


--
-- Name: bank bank_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.bank
    ADD CONSTRAINT bank_pkey PRIMARY KEY (bank_key);


--
-- Name: bus_model bus_model_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.bus_model
    ADD CONSTRAINT bus_model_pkey PRIMARY KEY (position_key, rpt_date);


--
-- Name: cash_flow cash_flow_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.cash_flow
    ADD CONSTRAINT cash_flow_pkey PRIMARY KEY (position_key);


--
-- Name: column_def_custom column_def_custom_pk; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.column_def_custom
    ADD CONSTRAINT column_def_custom_pk PRIMARY KEY (id_user, preset_code, grp);


--
-- Name: gdl gdl_pk; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.gdl
    ADD CONSTRAINT gdl_pk PRIMARY KEY (rpt_date, abi);


--
-- Name: hbe_position hbe_position_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.hbe_position
    ADD CONSTRAINT hbe_position_pkey PRIMARY KEY (position_key, starts_on);


--
-- Name: import_error import_error_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.import_error
    ADD CONSTRAINT import_error_pkey PRIMARY KEY (id);


--
-- Name: import_file import_file_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.import_file
    ADD CONSTRAINT import_file_pkey PRIMARY KEY (file_key);


--
-- Name: import_log import_log_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.import_log
    ADD CONSTRAINT import_log_pkey PRIMARY KEY (import_id);


--
-- Name: instrument instrument_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.instrument
    ADD CONSTRAINT instrument_pkey PRIMARY KEY (instrument_key, rpt_date);


--
-- Name: limit_dimensional_custom limit_dimensional_custom_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.limit_dimensional_custom
    ADD CONSTRAINT limit_dimensional_custom_pkey PRIMARY KEY (ptf_type, abi);


--
-- Name: limit_dimensional limit_dimensional_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.limit_dimensional
    ADD CONSTRAINT limit_dimensional_pkey PRIMARY KEY (ptf_type, abi);


--
-- Name: limit_value limit_value_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.limit_value
    ADD CONSTRAINT limit_value_pkey PRIMARY KEY (limit_value_key, rpt_date);


--
-- Name: limits_perc limits_perc_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.limits_perc
    ADD CONSTRAINT limits_perc_pkey PRIMARY KEY (limit_key);


--
-- Name: margin_hs margin_hs_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.margin_hs
    ADD CONSTRAINT margin_hs_pkey PRIMARY KEY (id);


--
-- Name: morningstar_category morningstar_category_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.morningstar_category
    ADD CONSTRAINT morningstar_category_pkey PRIMARY KEY (morningstar_category_key);


--
-- Name: part_order_test part_order_test_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.part_order_test
    ADD CONSTRAINT part_order_test_pkey PRIMARY KEY (rpt_date, abi);


--
-- Name: permission permission_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.permission
    ADD CONSTRAINT permission_pkey PRIMARY KEY (id);


--
-- Name: portfolio_info portfolio_info_pk; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.portfolio_info
    ADD CONSTRAINT portfolio_info_pk PRIMARY KEY (portfolioinfo_key, rpt_date);


--
-- Name: portfolio portfolio_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.portfolio
    ADD CONSTRAINT portfolio_pkey PRIMARY KEY (portfolio_key);


--
-- Name: position_link_rule position_link_rule_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.position_link_rule
    ADD CONSTRAINT position_link_rule_pkey PRIMARY KEY (origin, type);


--
-- Name: position position_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public."position"
    ADD CONSTRAINT position_pkey PRIMARY KEY (position_key, rpt_date);


--
-- Name: position_predeal position_predeal_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.position_predeal
    ADD CONSTRAINT position_predeal_pkey PRIMARY KEY (position_key);


--
-- Name: predeal predeal_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.predeal
    ADD CONSTRAINT predeal_pkey PRIMARY KEY (id);


--
-- Name: price price_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.price
    ADD CONSTRAINT price_pkey PRIMARY KEY (price_key);


--
-- Name: profile_has_permission profile_has_permission_pk; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.profile_has_permission
    ADD CONSTRAINT profile_has_permission_pk PRIMARY KEY (profile_code, permission_code);


--
-- Name: profile profile_pk; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.profile
    ADD CONSTRAINT profile_pk PRIMARY KEY (code);


--
-- Name: ref_apm_file_key ref_apm_file_key_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_apm_file_key
    ADD CONSTRAINT ref_apm_file_key_pkey PRIMARY KEY (file_key);


--
-- Name: ref_apm_file_loc ref_apm_file_loc_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_apm_file_loc
    ADD CONSTRAINT ref_apm_file_loc_pkey PRIMARY KEY (location_name);


--
-- Name: ref_apm_file ref_apm_file_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_apm_file
    ADD CONSTRAINT ref_apm_file_pkey PRIMARY KEY (file_key);


--
-- Name: ref_book_config ref_book_config_pk; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_book_config
    ADD CONSTRAINT ref_book_config_pk UNIQUE (abi, book, "from", "to");


--
-- Name: ref_city_to_region ref_city_to_region_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_city_to_region
    ADD CONSTRAINT ref_city_to_region_pkey PRIMARY KEY (city);


--
-- Name: ref_issuer ref_issuer_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_issuer
    ADD CONSTRAINT ref_issuer_pkey PRIMARY KEY (issuer_key);


--
-- Name: ref_limit_asset_class ref_limit_asset_class_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_limit_asset_class
    ADD CONSTRAINT ref_limit_asset_class_pkey PRIMARY KEY (value, asset_class_key);


--
-- Name: ref_limit_attribute_class ref_limit_attribute_class_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_limit_attribute_class
    ADD CONSTRAINT ref_limit_attribute_class_pkey PRIMARY KEY (value, type, attribute_class_key);


--
-- Name: ref_limit ref_limit_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_limit
    ADD CONSTRAINT ref_limit_pkey PRIMARY KEY (limit_key);


--
-- Name: ref_range ref_range_key; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_range
    ADD CONSTRAINT ref_range_key PRIMARY KEY (code, max);


--
-- Name: ref_rating ref_rating_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_rating
    ADD CONSTRAINT ref_rating_pkey PRIMARY KEY (rating_key);


--
-- Name: ref_rpt_date ref_rpt_date_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_rpt_date
    ADD CONSTRAINT ref_rpt_date_pkey PRIMARY KEY (rpt_date);


--
-- Name: ref_state ref_state_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_state
    ADD CONSTRAINT ref_state_pkey PRIMARY KEY (state_id);


--
-- Name: ref_state ref_state_state_key; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_state
    ADD CONSTRAINT ref_state_state_key UNIQUE (state);


--
-- Name: report report_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.report
    ADD CONSTRAINT report_pkey PRIMARY KEY (code);


--
-- Name: risk_market_data_fixing risk_market_data_fixing_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.risk_market_data_fixing
    ADD CONSTRAINT risk_market_data_fixing_pkey PRIMARY KEY (date, risk_market_data_fixing_key);


--
-- Name: risk_market_data risk_market_data_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.risk_market_data
    ADD CONSTRAINT risk_market_data_pkey PRIMARY KEY (risk_market_data_key, rpt_date);


--
-- Name: risk_pos risk_pos_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.risk_pos
    ADD CONSTRAINT risk_pos_pkey PRIMARY KEY (risk_pos_key, rpt_date);


--
-- Name: risk_ptf risk_ptf_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.risk_ptf
    ADD CONSTRAINT risk_ptf_pkey PRIMARY KEY (risk_ptf_key, rpt_date);


--
-- Name: role role_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_pkey PRIMARY KEY (id);


--
-- Name: rpt_position rpt_position_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.rpt_position
    ADD CONSTRAINT rpt_position_pkey PRIMARY KEY (rpt_date, position_key, starts_on);


--
-- Name: sector sector_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.sector
    ADD CONSTRAINT sector_pkey PRIMARY KEY (code);


--
-- Name: sensitivity sensitivity_pk; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.sensitivity
    ADD CONSTRAINT sensitivity_pk PRIMARY KEY (rpt_date, sensitivity_key);


--
-- Name: temp_prod_instrument temp_prod_instrument_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.temp_prod_instrument
    ADD CONSTRAINT temp_prod_instrument_pkey PRIMARY KEY (rpt_date, instrument_key);


--
-- Name: temp_prod_ref_issuer temp_prod_ref_issuer_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.temp_prod_ref_issuer
    ADD CONSTRAINT temp_prod_ref_issuer_pkey PRIMARY KEY (issuer_key);


--
-- Name: template template_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.template
    ADD CONSTRAINT template_pkey PRIMARY KEY (id);


--
-- Name: trade_hist trade_hist_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.trade_hist
    ADD CONSTRAINT trade_hist_pkey PRIMARY KEY (trade_key, starts_on);


--
-- Name: trade trade_pk; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.trade
    ADD CONSTRAINT trade_pk PRIMARY KEY (rpt_date, trade_key);


--
-- Name: trade_reconciliation trade_reconciliation_pk; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.trade_reconciliation
    ADD CONSTRAINT trade_reconciliation_pk PRIMARY KEY (trade_reconciliation_key, rpt_date);


--
-- Name: user_credential uk_6s3isow7rby7lajiubl6rcxkv; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.user_credential
    ADD CONSTRAINT uk_6s3isow7rby7lajiubl6rcxkv UNIQUE (username);


--
-- Name: template uk_7c4uia1pmvxb1btrw9i1k4eg8; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.template
    ADD CONSTRAINT uk_7c4uia1pmvxb1btrw9i1k4eg8 UNIQUE (code);


--
-- Name: portfolio uk_d3fiwmyl6j1uxr09mwl9axtbj; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.portfolio
    ADD CONSTRAINT uk_d3fiwmyl6j1uxr09mwl9axtbj UNIQUE (abi, desk);


--
-- Name: template uk_nk6tcv178yip1t1yxdv7v4nhd; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.template
    ADD CONSTRAINT uk_nk6tcv178yip1t1yxdv7v4nhd UNIQUE (description);


--
-- Name: user_credential user_credential_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.user_credential
    ADD CONSTRAINT user_credential_pkey PRIMARY KEY (id);


--
-- Name: user_permission user_permission_pk; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.user_permission
    ADD CONSTRAINT user_permission_pk PRIMARY KEY (code);


--
-- Name: user_profile user_profile_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.user_profile
    ADD CONSTRAINT user_profile_pkey PRIMARY KEY (id);


--
-- Name: verification_token verification_token_pkey; Type: CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.verification_token
    ADD CONSTRAINT verification_token_pkey PRIMARY KEY (id);


--
-- Name: abi_gdl_idx_abi; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX abi_gdl_idx_abi ON import.abi_gdl USING btree (abi);


--
-- Name: bond_def_cashflows_idx_securityid_ccy_date; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX bond_def_cashflows_idx_securityid_ccy_date ON import.bond_def_cashflows USING btree (securityid, ccy, date);


--
-- Name: customer_idx_id; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX customer_idx_id ON import.customer USING btree (id);


--
-- Name: eefgbci_bond_export_idx_tradeid_company_tradestatus_desk; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX eefgbci_bond_export_idx_tradeid_company_tradestatus_desk ON import.eefgbci_bond_export USING btree (tradeid, company, tradestatus, desk);


--
-- Name: eefgbci_swap_export_idx_tradeid_legtype; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX eefgbci_swap_export_idx_tradeid_legtype ON import.eefgbci_swap_export USING btree (tradeid, legtype);


--
-- Name: eefgbci_swap_trdetrep_cashflows_idx_tradeid; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX eefgbci_swap_trdetrep_cashflows_idx_tradeid ON import.eefgbci_swap_trdetrep_cashflows USING btree (tradeid);


--
-- Name: eefgbci_swap_trdetrep_cashflows_idx_tradeid_legtype; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX eefgbci_swap_trdetrep_cashflows_idx_tradeid_legtype ON import.eefgbci_swap_trdetrep_cashflows USING btree (tradeid, legtype);


--
-- Name: eefgbci_swap_trdetrep_tradedescription_idx_tradeid; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX eefgbci_swap_trdetrep_tradedescription_idx_tradeid ON import.eefgbci_swap_trdetrep_tradedescription USING btree (tradeid);


--
-- Name: eefgbci_swap_trdetrep_tradedescription_idx_tradeid_legtype; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX eefgbci_swap_trdetrep_tradedescription_idx_tradeid_legtype ON import.eefgbci_swap_trdetrep_tradedescription USING btree (tradeid, legtype);


--
-- Name: eefgbci_swap_trdetrep_tradevaluation_idx_tradeid; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX eefgbci_swap_trdetrep_tradevaluation_idx_tradeid ON import.eefgbci_swap_trdetrep_tradevaluation USING btree (tradeid);


--
-- Name: eefgbci_swap_trdetrep_tradevaluation_idx_tradeid_legtype; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX eefgbci_swap_trdetrep_tradevaluation_idx_tradeid_legtype ON import.eefgbci_swap_trdetrep_tradevaluation USING btree (tradeid, legtype);


--
-- Name: finance_rpt_date_idx; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE UNIQUE INDEX finance_rpt_date_idx ON import.finance USING btree (rpt_date, finance_key);


--
-- Name: fk_hbe_position; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX fk_hbe_position ON import.trade USING btree (trade_key, starts_on);


--
-- Name: ix_bus_model_rpt_date; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX ix_bus_model_rpt_date ON import.bus_model USING btree (rpt_date);


--
-- Name: ix_position_rpt_date; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX ix_position_rpt_date ON import."position" USING btree (rpt_date);


--
-- Name: limit_value_ia_name_ia_id_rpt_date_abi_index; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX limit_value_ia_name_ia_id_rpt_date_abi_index ON import.limit_value USING btree (ia_name, ia_id, rpt_date, abi);


--
-- Name: limit_value_limit_key_abi_index; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX limit_value_limit_key_abi_index ON import.limit_value USING btree (limit_key, abi);


--
-- Name: location_idx_loccustid; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX location_idx_loccustid ON import.location USING btree (loccustid);


--
-- Name: m50_idx_abi_conto; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX m50_idx_abi_conto ON import.m50 USING btree (abi, conto);


--
-- Name: portfolio_info_rpt_date_idx; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE UNIQUE INDEX portfolio_info_rpt_date_idx ON import.portfolio_info USING btree (rpt_date, portfolioinfo_key);


--
-- Name: position_desk_abi_idx; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX position_desk_abi_idx ON import."position" USING btree (desk, abi);


--
-- Name: pzgias_idx_isin_ccy; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX pzgias_idx_isin_ccy ON import.pzgias USING btree (isin, ccy);


--
-- Name: reserve_oci_bond_idx_company_desk_isin; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX reserve_oci_bond_idx_company_desk_isin ON import.reserve_oci_bond USING btree (company, desk, isin);


--
-- Name: reserve_oci_equity_idx_company_desk_isin; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX reserve_oci_equity_idx_company_desk_isin ON import.reserve_oci_equity USING btree (company, desk, isin);


--
-- Name: risk_suite_market_data_idx_indexname_currency_term; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX risk_suite_market_data_idx_indexname_currency_term ON import.risk_suite_market_data USING btree (indexname, currency, term);


--
-- Name: risk_suite_risk_limits_idx_icid_abi_rllimitname; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX risk_suite_risk_limits_idx_icid_abi_rllimitname ON import.risk_suite_risk_limits USING btree (icid, abi, rllimitname);


--
-- Name: risk_suite_risk_limits_idx_referencedate; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX risk_suite_risk_limits_idx_referencedate ON import.risk_suite_risk_limits USING btree (referencedate);


--
-- Name: risk_suite_risk_measures_aggr_idx_portbankid_posaggregatename_a; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX risk_suite_risk_measures_aggr_idx_portbankid_posaggregatename_a ON import.risk_suite_risk_measures_aggr USING btree (portbankid, posaggregatename, aggregatename);


--
-- Name: risk_suite_risk_measures_idx_portbankid_posaggregatename_isin; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX risk_suite_risk_measures_idx_portbankid_posaggregatename_isin ON import.risk_suite_risk_measures USING btree (portbankid, posaggregatename, isin);


--
-- Name: sec_idx_sec_ccy; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX sec_idx_sec_ccy ON import.sec USING btree (sec, ccy);


--
-- Name: sec_pos_rep_idx_company; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX sec_pos_rep_idx_company ON import.sec_pos_rep USING btree (company);


--
-- Name: sec_pos_rep_idx_company_desk_book_security; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX sec_pos_rep_idx_company_desk_book_security ON import.sec_pos_rep USING btree (company, desk, book, security);


--
-- Name: sec_pos_rep_idx_security; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX sec_pos_rep_idx_security ON import.sec_pos_rep USING btree (security);


--
-- Name: stock_idx_exchange_ticker; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX stock_idx_exchange_ticker ON import.stock USING btree (exchange, ticker);


--
-- Name: trade_pl_bond_idx_company_desk_book_sec; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX trade_pl_bond_idx_company_desk_book_sec ON import.trade_pl_bond USING btree (company, desk, book, sec);


--
-- Name: trade_pl_equity_idx_exchange_ticker_company_desk_book; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX trade_pl_equity_idx_exchange_ticker_company_desk_book ON import.trade_pl_equity USING btree (exchange, ticker, company, desk, book);


--
-- Name: trade_pl_swap_idx_tradeid; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX trade_pl_swap_idx_tradeid ON import.trade_pl_swap USING btree (tradeid);


--
-- Name: trade_pl_swap_idx_tradeid_legtype; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX trade_pl_swap_idx_tradeid_legtype ON import.trade_pl_swap USING btree (tradeid, legtype);


--
-- Name: trade_pl_swap_idx_tradeid_legtype_company_desk_book_secid; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX trade_pl_swap_idx_tradeid_legtype_company_desk_book_secid ON import.trade_pl_swap USING btree (tradeid, legtype, company, desk, book, secid);


--
-- Name: trade_plbm_bond_idx_company_sec_ccy_businessmodel; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX trade_plbm_bond_idx_company_sec_ccy_businessmodel ON import.trade_plbm_bond USING btree (company, sec, ccy, businessmodel);


--
-- Name: uplift_gebonamo_idx_tradeid; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX uplift_gebonamo_idx_tradeid ON import.uplift_gebonamo USING btree (tradeid);


--
-- Name: x5_finance_idx_cod_banca_modello_di_business_sub_modello_di_bus; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX x5_finance_idx_cod_banca_modello_di_business_sub_modello_di_bus ON import.x5_finance USING btree (cod_banca, modello_di_business, sub_modello_di_business, cod_strumento_finanziario, divisa_di_trattazione_suffisso);


--
-- Name: x5_finance_idx_modello_di_business_sub_modello_di_business; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX x5_finance_idx_modello_di_business_sub_modello_di_business ON import.x5_finance USING btree (modello_di_business, sub_modello_di_business);


--
-- Name: xie_instrument_isin; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX xie_instrument_isin ON import.instrument USING btree (rpt_date, isin);


--
-- Name: xm_finance_idx_cod_banca_modello_di_business_sub_modello_di_bus; Type: INDEX; Schema: import; Owner: exa_db
--

CREATE INDEX xm_finance_idx_cod_banca_modello_di_business_sub_modello_di_bus ON import.xm_finance USING btree (cod_banca, modello_di_business, sub_modello_di_business, cod_strumento_finanziario, divisa_di_trattazione_suffisso);


--
-- Name: ak_apm_file_log_archive_name; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX ak_apm_file_log_archive_name ON public.apm_file_log USING btree (archive_uri) WHERE (archive_uri IS NOT NULL);


--
-- Name: ak_display_date; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX ak_display_date ON public.ref_rpt_date USING btree (display_date) WHERE (state_id = ANY (ARRAY[40000, 80000]));


--
-- Name: ak_import_log_archive_name; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX ak_import_log_archive_name ON public.import_log USING btree (archive_uri);


--
-- Name: ak_mview_file_loc; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX ak_mview_file_loc ON public.mview_file_loc USING btree (file_key, location_name);


--
-- Name: book_rpt_date_abi_desk_book_delega_position_type_idx; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX book_rpt_date_abi_desk_book_delega_position_type_idx ON public.book USING btree (rpt_date, abi, desk, book, position_type, delega);


--
-- Name: book_rpt_date_abi_desk_book_idx; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX book_rpt_date_abi_desk_book_idx ON public.book USING btree (rpt_date, abi, desk, book);


--
-- Name: book_rpt_date_abi_desk_book_position_type_idx; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX book_rpt_date_abi_desk_book_position_type_idx ON public.book USING btree (rpt_date, abi, desk, book, position_type);


--
-- Name: book_rpt_date_portfolio_key_idx; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX book_rpt_date_portfolio_key_idx ON public.book USING btree (rpt_date, portfolio_key);


--
-- Name: book_rpt_date_portfolio_key_position_type_idx; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX book_rpt_date_portfolio_key_position_type_idx ON public.book USING btree (rpt_date, portfolio_key, position_type);


--
-- Name: config_key_idx; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX config_key_idx ON public.config USING btree (key);


--
-- Name: finance_rpt_date_idx; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX finance_rpt_date_idx ON public.finance USING btree (rpt_date, finance_key);


--
-- Name: fk_hbe_position; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX fk_hbe_position ON public.trade USING btree (trade_key, starts_on);


--
-- Name: fk_hbe_positionì; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX "fk_hbe_positionì" ON public.rpt_position USING btree (position_key, starts_on);


--
-- Name: idx_instrument_asset_class; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX idx_instrument_asset_class ON public.instrument USING btree (rpt_date, asset_class_key, instrument_key);


--
-- Name: idx_position_book; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX idx_position_book ON public."position" USING btree (rpt_date, book, portfolio_key);


--
-- Name: idx_position_desk; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX idx_position_desk ON public."position" USING btree (rpt_date, desk, abi);


--
-- Name: idx_position_portfolio_position_type; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX idx_position_portfolio_position_type ON public."position" USING btree (rpt_date, portfolio_key, position_type, instrument_key);


--
-- Name: idx_prod_instrument_asset_class; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX idx_prod_instrument_asset_class ON public.temp_prod_instrument USING btree (rpt_date, asset_class_key, instrument_key);


--
-- Name: idx_risk_market_data_index_name; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX idx_risk_market_data_index_name ON public.risk_market_data USING btree (rpt_date, index_name);


--
-- Name: idx_risk_ptf_index_name; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX idx_risk_ptf_index_name ON public.risk_ptf USING btree (rpt_date, portfolio_key, aggregation_name);


--
-- Name: ifk_position_parent; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX ifk_position_parent ON public."position" USING btree (parent_rpt_date, parent_position_key);


--
-- Name: ix_apm_file_log_date_file_key; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX ix_apm_file_log_date_file_key ON public.apm_file_log USING btree (rpt_date, file_key);


--
-- Name: ix_apm_file_log_file_key; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX ix_apm_file_log_file_key ON public.apm_file_log USING btree (file_key);


--
-- Name: ix_apm_file_log_parent; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX ix_apm_file_log_parent ON public.apm_file_log USING btree (parent_import_id);


--
-- Name: ix_apm_file_log_state_id; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX ix_apm_file_log_state_id ON public.apm_file_log USING btree (state_id);


--
-- Name: ix_bus_model_rpt_date; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX ix_bus_model_rpt_date ON public.bus_model USING btree (rpt_date);


--
-- Name: ix_import_log_file_key; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX ix_import_log_file_key ON public.import_log USING btree (file_key);


--
-- Name: ix_import_log_rpt_date; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX ix_import_log_rpt_date ON public.import_log USING btree (rpt_date, file_key);


--
-- Name: ix_import_log_state_id; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX ix_import_log_state_id ON public.import_log USING btree (state_id);


--
-- Name: ix_position_rpt_date; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX ix_position_rpt_date ON public."position" USING btree (rpt_date);


--
-- Name: limit_value_ia_name_ia_id_rpt_date_abi_index; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX limit_value_ia_name_ia_id_rpt_date_abi_index ON public.limit_value USING btree (ia_name, ia_id, rpt_date, abi);


--
-- Name: limit_value_limit_key_abi_index; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX limit_value_limit_key_abi_index ON public.limit_value USING btree (limit_key, abi);


--
-- Name: portfolio_info_rpt_date_idx; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX portfolio_info_rpt_date_idx ON public.portfolio_info USING btree (rpt_date, portfolioinfo_key);


--
-- Name: profile_code_uindex; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX profile_code_uindex ON public.profile USING btree (code);


--
-- Name: ref_limit_limit_key_abi_index; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX ref_limit_limit_key_abi_index ON public.ref_limit USING btree (limit_key, abi);


--
-- Name: risk_market_data_fixing_date_idx; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX risk_market_data_fixing_date_idx ON public.risk_market_data_fixing USING btree (date, risk_market_data_fixing_key);


--
-- Name: user_permission_code_uindex; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX user_permission_code_uindex ON public.user_permission USING btree (code);


--
-- Name: xak_hbe_position_current; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX xak_hbe_position_current ON public.trade_hist USING btree (ends_on, trade_key);


--
-- Name: xak_hbe_positionì_current; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE UNIQUE INDEX "xak_hbe_positionì_current" ON public.hbe_position USING btree (ends_on, position_key);


--
-- Name: xie_instrument_isin; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX xie_instrument_isin ON public.instrument USING btree (rpt_date, isin);


--
-- Name: xie_limit_value_view; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX xie_limit_value_view ON public.limit_value USING btree (rpt_date, abi, limit_key, ia_name);


--
-- Name: xie_prod_instrument_isin; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX xie_prod_instrument_isin ON public.temp_prod_instrument USING btree (rpt_date, isin);


--
-- Name: xie_ref_limit_view; Type: INDEX; Schema: public; Owner: exa_db
--

CREATE INDEX xie_ref_limit_view ON public.ref_limit USING btree (limit_key, desk);


--
-- Name: bus_model bus_model_bank; Type: FK CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.bus_model
    ADD CONSTRAINT bus_model_bank FOREIGN KEY (abi) REFERENCES public.bank(bank_key);


--
-- Name: bus_model bus_model_instrument; Type: FK CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.bus_model
    ADD CONSTRAINT bus_model_instrument FOREIGN KEY (instrument_key, rpt_date) REFERENCES import.instrument(instrument_key, rpt_date);


--
-- Name: bus_model bus_model_parent; Type: FK CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.bus_model
    ADD CONSTRAINT bus_model_parent FOREIGN KEY (parent_position_key, parent_rpt_date) REFERENCES import.bus_model(position_key, rpt_date);


--
-- Name: instrument fk62pxeqwihkss8cu73osxn6dti; Type: FK CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.instrument
    ADD CONSTRAINT fk62pxeqwihkss8cu73osxn6dti FOREIGN KEY (rating_key) REFERENCES public.ref_rating(rating_key);


--
-- Name: test_jwrite_main fk_city; Type: FK CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.test_jwrite_main
    ADD CONSTRAINT fk_city FOREIGN KEY (city_key) REFERENCES import.test_jwrite_city(city_key);


--
-- Name: instrument fkaxdekskyx55idvuqx0ajjqj9i; Type: FK CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.instrument
    ADD CONSTRAINT fkaxdekskyx55idvuqx0ajjqj9i FOREIGN KEY (issuer_key) REFERENCES public.ref_issuer(issuer_key);


--
-- Name: position fkjj73ovv9odu76jsmcdobl8w39; Type: FK CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import."position"
    ADD CONSTRAINT fkjj73ovv9odu76jsmcdobl8w39 FOREIGN KEY (instrument_key, rpt_date) REFERENCES import.instrument(instrument_key, rpt_date);


--
-- Name: position fkjv3dpnudgejldfxq2a8x42wq8; Type: FK CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import."position"
    ADD CONSTRAINT fkjv3dpnudgejldfxq2a8x42wq8 FOREIGN KEY (abi) REFERENCES public.bank(bank_key);


--
-- Name: instrument fkp45wkigtyrqfpg9p4owt1h3mj; Type: FK CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import.instrument
    ADD CONSTRAINT fkp45wkigtyrqfpg9p4owt1h3mj FOREIGN KEY (price_key) REFERENCES public.price(price_key);


--
-- Name: position fksk0n0xc776yrel6voblttxcak; Type: FK CONSTRAINT; Schema: import; Owner: exa_db
--

ALTER TABLE ONLY import."position"
    ADD CONSTRAINT fksk0n0xc776yrel6voblttxcak FOREIGN KEY (parent_position_key, parent_rpt_date) REFERENCES import."position"(position_key, rpt_date);


--
-- Name: bus_model bus_model_bank; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.bus_model
    ADD CONSTRAINT bus_model_bank FOREIGN KEY (abi) REFERENCES public.bank(bank_key);


--
-- Name: bus_model bus_model_instrument; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.bus_model
    ADD CONSTRAINT bus_model_instrument FOREIGN KEY (instrument_key, rpt_date) REFERENCES public.instrument(instrument_key, rpt_date);


--
-- Name: bus_model bus_model_parent; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.bus_model
    ADD CONSTRAINT bus_model_parent FOREIGN KEY (parent_position_key, parent_rpt_date) REFERENCES public.bus_model(position_key, rpt_date);


--
-- Name: role_has_permission fk2h8xukv5c6o207f1iyj555146; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.role_has_permission
    ADD CONSTRAINT fk2h8xukv5c6o207f1iyj555146 FOREIGN KEY (permission_id) REFERENCES public.permission(id);


--
-- Name: bank fk60gtv93rnrn9a1btqerfsva3t; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.bank
    ADD CONSTRAINT fk60gtv93rnrn9a1btqerfsva3t FOREIGN KEY (city) REFERENCES public.ref_city_to_region(city);


--
-- Name: instrument fk62pxeqwihkss8cu73osxn6dti; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.instrument
    ADD CONSTRAINT fk62pxeqwihkss8cu73osxn6dti FOREIGN KEY (rating_key) REFERENCES public.ref_rating(rating_key);


--
-- Name: rpt_position fk_hbe_position; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.rpt_position
    ADD CONSTRAINT fk_hbe_position FOREIGN KEY (position_key, starts_on) REFERENCES public.hbe_position(position_key, starts_on);


--
-- Name: import_log fk_import_file; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.import_log
    ADD CONSTRAINT fk_import_file FOREIGN KEY (file_key) REFERENCES public.import_file(file_key);


--
-- Name: apm_file_log fk_parent_import_id; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.apm_file_log
    ADD CONSTRAINT fk_parent_import_id FOREIGN KEY (parent_import_id) REFERENCES public.apm_file_log(import_id);


--
-- Name: apm_import_rec fk_parent_import_rec_id; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.apm_import_rec
    ADD CONSTRAINT fk_parent_import_rec_id FOREIGN KEY (parent_import_rec_id) REFERENCES public.apm_import_rec(import_rec_id);


--
-- Name: apm_file_log fk_ref_apm_file; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.apm_file_log
    ADD CONSTRAINT fk_ref_apm_file FOREIGN KEY (file_key) REFERENCES public.ref_apm_file_key(file_key);


--
-- Name: apm_import_rec fk_ref_apm_file; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.apm_import_rec
    ADD CONSTRAINT fk_ref_apm_file FOREIGN KEY (file_key) REFERENCES public.ref_apm_file_key(file_key);


--
-- Name: apm_file_log fk_ref_state; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.apm_file_log
    ADD CONSTRAINT fk_ref_state FOREIGN KEY (state_id) REFERENCES public.ref_state(state_id);


--
-- Name: ref_rpt_date fk_state; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_rpt_date
    ADD CONSTRAINT fk_state FOREIGN KEY (state_id) REFERENCES public.ref_state(state_id);


--
-- Name: import_log fk_state; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.import_log
    ADD CONSTRAINT fk_state FOREIGN KEY (state_id) REFERENCES public.ref_state(state_id);


--
-- Name: trade fk_trade_hist; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.trade
    ADD CONSTRAINT fk_trade_hist FOREIGN KEY (trade_key, starts_on) REFERENCES public.trade_hist(trade_key, starts_on);


--
-- Name: instrument fkaxdekskyx55idvuqx0ajjqj9i; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.instrument
    ADD CONSTRAINT fkaxdekskyx55idvuqx0ajjqj9i FOREIGN KEY (issuer_key) REFERENCES public.ref_issuer(issuer_key);


--
-- Name: predeal fkba4hm62kuagd0iipga98931h7; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.predeal
    ADD CONSTRAINT fkba4hm62kuagd0iipga98931h7 FOREIGN KEY (owner_predeal) REFERENCES public.user_credential(id);


--
-- Name: portfolio fkbteliantepm7jdp8b0i9u1qtg; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.portfolio
    ADD CONSTRAINT fkbteliantepm7jdp8b0i9u1qtg FOREIGN KEY (abi) REFERENCES public.bank(bank_key);


--
-- Name: user_has_role fkc1m07gjgx777ukpfw6wa94dfh; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.user_has_role
    ADD CONSTRAINT fkc1m07gjgx777ukpfw6wa94dfh FOREIGN KEY (role_id) REFERENCES public.role(id);


--
-- Name: role_has_permission fkc616yaiie179glys9ee1gwsod; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.role_has_permission
    ADD CONSTRAINT fkc616yaiie179glys9ee1gwsod FOREIGN KEY (role_id) REFERENCES public.role(id);


--
-- Name: ref_limit fkd4jyixs1pdbss0hprywqru6po; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.ref_limit
    ADD CONSTRAINT fkd4jyixs1pdbss0hprywqru6po FOREIGN KEY (parent_id) REFERENCES public.ref_limit(limit_key);


--
-- Name: position fkjj73ovv9odu76jsmcdobl8w39; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public."position"
    ADD CONSTRAINT fkjj73ovv9odu76jsmcdobl8w39 FOREIGN KEY (instrument_key, rpt_date) REFERENCES public.instrument(instrument_key, rpt_date);


--
-- Name: user_has_role fkjn1ej01kkw1n9e8gmrvel6rie; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.user_has_role
    ADD CONSTRAINT fkjn1ej01kkw1n9e8gmrvel6rie FOREIGN KEY (user_id) REFERENCES public.user_credential(id);


--
-- Name: position fkjv3dpnudgejldfxq2a8x42wq8; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public."position"
    ADD CONSTRAINT fkjv3dpnudgejldfxq2a8x42wq8 FOREIGN KEY (abi) REFERENCES public.bank(bank_key);


--
-- Name: verification_token fkkgiaq4iplyjd79nqy92o680fr; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.verification_token
    ADD CONSTRAINT fkkgiaq4iplyjd79nqy92o680fr FOREIGN KEY (user_id) REFERENCES public.user_credential(id);


--
-- Name: position_predeal fkod4hnri8qu1d9sq8ymg56yfon; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.position_predeal
    ADD CONSTRAINT fkod4hnri8qu1d9sq8ymg56yfon FOREIGN KEY (predeal_key) REFERENCES public.predeal(id);


--
-- Name: instrument fkp45wkigtyrqfpg9p4owt1h3mj; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.instrument
    ADD CONSTRAINT fkp45wkigtyrqfpg9p4owt1h3mj FOREIGN KEY (price_key) REFERENCES public.price(price_key);


--
-- Name: user_profile fkrklypgte6ij3ny946d74r9md5; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.user_profile
    ADD CONSTRAINT fkrklypgte6ij3ny946d74r9md5 FOREIGN KEY (user_id) REFERENCES public.user_credential(id);


--
-- Name: position fksk0n0xc776yrel6voblttxcak; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public."position"
    ADD CONSTRAINT fksk0n0xc776yrel6voblttxcak FOREIGN KEY (parent_position_key, parent_rpt_date) REFERENCES public."position"(position_key, rpt_date);


--
-- Name: profile_has_permission profile_has_permission_profile_code_fk; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.profile_has_permission
    ADD CONSTRAINT profile_has_permission_profile_code_fk FOREIGN KEY (profile_code) REFERENCES public.profile(code);


--
-- Name: profile_has_permission profile_has_permission_user_permission_code_fk; Type: FK CONSTRAINT; Schema: public; Owner: exa_db
--

ALTER TABLE ONLY public.profile_has_permission
    ADD CONSTRAINT profile_has_permission_user_permission_code_fk FOREIGN KEY (permission_code) REFERENCES public.user_permission(code);


--
-- Name: SCHEMA import; Type: ACL; Schema: -; Owner: postgres
--

GRANT ALL ON SCHEMA import TO exa_db;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: cloudsqlsuperuser
--

REVOKE ALL ON SCHEMA public FROM cloudsqladmin;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO cloudsqlsuperuser;
GRANT ALL ON SCHEMA public TO PUBLIC;


--
-- Name: PROCEDURE p_insert_limit_value(in_rpt_date date, in_limit_value_key character varying, in_limit_key character varying, in_limit_display character varying, in_abi character varying, in_ia_id character varying, in_ia_name character varying, in_ia_description character varying, in_ic_id character varying, in_ic_description character varying, in_l1max numeric, in_l1max_perc numeric, in_l1min numeric, in_l1min_perc numeric, in_l2max numeric, in_l2max_perc numeric, in_l2min numeric, in_l2min_perc numeric, in_max numeric, in_max_perc numeric, in_min numeric, in_min_perc numeric, in_rl_limit_name character varying, in_rp_exceed boolean, in_rp_in_limits character varying, in_rp_value numeric); Type: ACL; Schema: public; Owner: exa_db
--

GRANT ALL ON PROCEDURE public.p_insert_limit_value(in_rpt_date date, in_limit_value_key character varying, in_limit_key character varying, in_limit_display character varying, in_abi character varying, in_ia_id character varying, in_ia_name character varying, in_ia_description character varying, in_ic_id character varying, in_ic_description character varying, in_l1max numeric, in_l1max_perc numeric, in_l1min numeric, in_l1min_perc numeric, in_l2max numeric, in_l2max_perc numeric, in_l2min numeric, in_l2min_perc numeric, in_max numeric, in_max_perc numeric, in_min numeric, in_min_perc numeric, in_rl_limit_name character varying, in_rp_exceed boolean, in_rp_in_limits character varying, in_rp_value numeric) TO import_user;


--
-- Name: PROCEDURE p_upsert_limit_value(in_rpt_date date, in_limit_value_key character varying, in_reference_date date, in_limit_key character varying, in_limit_display character varying, in_abi character varying, in_ia_id character varying, in_ia_name character varying, in_ia_description character varying, in_ic_id character varying, in_ic_description character varying, in_l1max numeric, in_l1max_perc numeric, in_l1min numeric, in_l1min_perc numeric, in_l2max numeric, in_l2max_perc numeric, in_l2min numeric, in_l2min_perc numeric, in_max numeric, in_max_perc numeric, in_min numeric, in_min_perc numeric, in_rl_limit_name character varying, in_rp_exceed boolean, in_rp_in_limits character varying, in_rp_value numeric); Type: ACL; Schema: public; Owner: exa_db
--

GRANT ALL ON PROCEDURE public.p_upsert_limit_value(in_rpt_date date, in_limit_value_key character varying, in_reference_date date, in_limit_key character varying, in_limit_display character varying, in_abi character varying, in_ia_id character varying, in_ia_name character varying, in_ia_description character varying, in_ic_id character varying, in_ic_description character varying, in_l1max numeric, in_l1max_perc numeric, in_l1min numeric, in_l1min_perc numeric, in_l2max numeric, in_l2max_perc numeric, in_l2min numeric, in_l2min_perc numeric, in_max numeric, in_max_perc numeric, in_min numeric, in_min_perc numeric, in_rl_limit_name character varying, in_rp_exceed boolean, in_rp_in_limits character varying, in_rp_value numeric) TO import_user;


--
-- Name: TABLE limit_value; Type: ACL; Schema: public; Owner: exa_db
--

GRANT ALL ON TABLE public.limit_value TO import_user;


--
-- PostgreSQL database dump complete
--

