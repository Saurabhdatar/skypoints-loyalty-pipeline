-- "Latest record wins" split into per-country tables, designed for billions of rows.
-- Identity: MEMBER_KEY. The pipe feed has a global Member_Id (key = id). The USA/AUS/IND extracts each number members
-- 1,2,3... independently, so their key is '<SRC>-<id>'. Using the bare id would merge three different people.
-- Ordering: (feed_ts, _file_row). Rules:
--  1. Within a batch keep only the newest record per member_key.
--  2. A record never overwrites a newer one already loaded (late / replayed files are safe).
--  3. If the member's country changed, delete the old country row; the registry tells us where it lived.
--  4. Idempotent: replaying the same batch gives the same end state.
CREATE OR REPLACE PROCEDURE CORE.SP_SPLIT_MEMBERS_BY_COUNTRY(P_FILE VARCHAR)
RETURNS VARCHAR LANGUAGE SQL AS
$$
DECLARE
  v_moved NUMBER DEFAULT 0;
  v_sel VARCHAR;
BEGIN
  CREATE OR REPLACE TEMPORARY TABLE CORE._BATCH AS
  SELECT * EXCLUDE (source, dq_status, dq_errors, country_src, _file_name, _file_row)
  FROM STG.MEMBER_STG WHERE _file_name = :P_FILE AND dq_status <> 'REJECT'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY member_key ORDER BY feed_ts DESC, _file_row DESC) = 1;

  CREATE OR REPLACE TEMPORARY TABLE CORE._MOVERS AS
  SELECT b.member_key, r.country_code AS old_country
  FROM CORE._BATCH b JOIN CORE.MEMBER_COUNTRY_REGISTRY r USING (member_key)
  WHERE r.country_code <> b.country_code AND b.feed_ts > r.feed_ts;
  v_moved := (SELECT COUNT(*) FROM CORE._MOVERS);

  FOR rec IN (SELECT DISTINCT m.target_table FROM CORE._MOVERS mv
              JOIN REF.COUNTRY_MAP m ON m.country_code = mv.old_country) DO
    EXECUTE IMMEDIATE 'DELETE FROM CORE.' || rec.target_table || ' t USING CORE._MOVERS mv WHERE t.member_key = mv.member_key';
  END FOR;

  FOR rec IN (SELECT DISTINCT m.target_table, m.country_code FROM REF.COUNTRY_MAP m
              JOIN CORE._BATCH b ON b.country_code = m.country_code) DO
    EXECUTE IMMEDIATE 'CREATE TABLE IF NOT EXISTS CORE.' || rec.target_table || ' LIKE CORE.MEMBER_TEMPLATE';
    EXECUTE IMMEDIATE
      'MERGE INTO CORE.' || rec.target_table || ' t USING (SELECT * FROM CORE._BATCH WHERE country_code = ''' || rec.country_code || ''') s
         ON t.member_key = s.member_key
       WHEN MATCHED AND s.feed_ts >= t.feed_ts THEN UPDATE SET
         member_id=s.member_id, member_type=s.member_type, member_name=s.member_name, enrollment_date=s.enrollment_date,
         last_flight_date=s.last_flight_date, tier_code=s.tier_code, agent_name=s.agent_name, state=s.state,
         country_code=s.country_code, post_code=s.post_code, dob=s.dob, is_active=s.is_active, age=s.age,
         stale_member=s.stale_member, feed_ts=s.feed_ts, updated_at=CURRENT_TIMESTAMP()
       WHEN NOT MATCHED THEN INSERT (member_key,member_id,member_type,member_name,enrollment_date,last_flight_date,tier_code,
         agent_name,state,country_code,post_code,dob,is_active,age,stale_member,feed_ts)
         VALUES (s.member_key,s.member_id,s.member_type,s.member_name,s.enrollment_date,s.last_flight_date,s.tier_code,
         s.agent_name,s.state,s.country_code,s.post_code,s.dob,s.is_active,s.age,s.stale_member,s.feed_ts)';
  END FOR;

  MERGE INTO CORE.MEMBER_COUNTRY_REGISTRY r USING CORE._BATCH b ON r.member_key = b.member_key
  WHEN MATCHED AND b.feed_ts > r.feed_ts THEN UPDATE SET country_code = b.country_code, feed_ts = b.feed_ts
  WHEN NOT MATCHED THEN INSERT (member_key, country_code, feed_ts) VALUES (b.member_key, b.country_code, b.feed_ts);

  v_sel := (SELECT LISTAGG('SELECT * FROM CORE.' || table_name, ' UNION ALL BY NAME ')
            FROM SKYPOINTS.INFORMATION_SCHEMA.TABLES
            WHERE table_schema = 'CORE' AND table_name IN (SELECT DISTINCT target_table FROM REF.COUNTRY_MAP));
  EXECUTE IMMEDIATE 'CREATE OR REPLACE VIEW CORE.V_MEMBER_ALL AS ' || v_sel;
  RETURN 'moved ' || v_moved || ' members between countries';
END;
$$;
-- Scale notes: set-based MERGEs on a clustered key. The registry means a move touches exactly two tables, never all N.
-- Orchestrate per file with a Snowflake TASK/stream or Airflow; size the warehouse up for backfills.
