-- SkyPoints loyalty pipeline: Snowflake DDL
-- Layers: RAW (landing, all strings, immutable) -> STG (typed + derived + DQ) -> CORE (country tables)
CREATE DATABASE IF NOT EXISTS SKYPOINTS;
CREATE SCHEMA IF NOT EXISTS SKYPOINTS.RAW;
CREATE SCHEMA IF NOT EXISTS SKYPOINTS.STG;
CREATE SCHEMA IF NOT EXISTS SKYPOINTS.CORE;
CREATE SCHEMA IF NOT EXISTS SKYPOINTS.DQ;
CREATE SCHEMA IF NOT EXISTS SKYPOINTS.REF;

-- ---------- REF: country standardisation (feeds mix ISO-2/ISO-3/short names: USA, IND, PHIL, CAN, AU) ----------
CREATE TABLE IF NOT EXISTS REF.COUNTRY_MAP (
    source_code   VARCHAR(5)  NOT NULL,   -- as received, upper-cased
    country_code  VARCHAR(2)  NOT NULL,   -- canonical ISO 3166 alpha-2
    country_name  VARCHAR(60) NOT NULL,
    target_table  VARCHAR(60) NOT NULL,   -- e.g. TABLE_INDIA
    PRIMARY KEY (source_code)
);
MERGE INTO REF.COUNTRY_MAP t USING (
    SELECT * FROM VALUES
      ('USA','US','USA','TABLE_USA'),('US','US','USA','TABLE_USA'),
      ('IND','IN','India','TABLE_INDIA'),('IN','IN','India','TABLE_INDIA'),
      ('PHIL','PH','Philippines','TABLE_PHILIPPINES'),('PH','PH','Philippines','TABLE_PHILIPPINES'),
      ('CAN','CA','Canada','TABLE_CANADA'),('CA','CA','Canada','TABLE_CANADA'),
      ('AU','AU','Australia','TABLE_AUSTRALIA'),('AUS','AU','Australia','TABLE_AUSTRALIA')
    AS v(source_code,country_code,country_name,target_table)) s
ON t.source_code = s.source_code
WHEN NOT MATCHED THEN INSERT VALUES (s.source_code,s.country_code,s.country_name,s.target_table);

-- How each source writes its dates (drives STG.F_PARSE_DATE). YMD=20101012  ISO=2022-05-11  DMY=1/1/2022
-- MDY=6/15/2022 or unpadded digits 6152022  DMY8=03051985 (leading zero often lost)
CREATE TABLE IF NOT EXISTS REF.SOURCE_PROFILE (source VARCHAR PRIMARY KEY, date_style VARCHAR, dob_style VARCHAR);
MERGE INTO REF.SOURCE_PROFILE t USING (SELECT * FROM VALUES
    ('PIPE','YMD','DMY8'),('USA','MDY','MDY'),('AUS','ISO','ISO'),('IND','DMY','DMY') AS v(source,date_style,dob_style)) s
ON t.source = s.source WHEN NOT MATCHED THEN INSERT VALUES (s.source,s.date_style,s.dob_style);

-- ---------- RAW: landing. Every field VARCHAR so nothing is ever rejected at load time ----------
CREATE TABLE IF NOT EXISTS RAW.MEMBER_FEED_RAW (
    record_type    VARCHAR,           -- 'H' / 'D'
    member_name    VARCHAR, member_id VARCHAR, enrollment_date VARCHAR, last_flight_date VARCHAR,
    tier_code      VARCHAR, agent_name VARCHAR, state VARCHAR, country VARCHAR,
    post_code      VARCHAR, dob VARCHAR, is_active VARCHAR,
    _file_name     VARCHAR       NOT NULL,
    _file_row      NUMBER        NOT NULL,
    _loaded_at     TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
) CLUSTER BY (_file_name);

-- Per-country extracts arrive with their own layouts; file name gives the country. Each keeps its native columns.
CREATE TABLE IF NOT EXISTS RAW.MEMBER_USA_RAW (id VARCHAR, name VARCHAR, tier_code VARCHAR, enrollment_date VARCHAR,
    flight_date VARCHAR, _file_name VARCHAR NOT NULL, _file_row NUMBER NOT NULL, _loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());
CREATE TABLE IF NOT EXISTS RAW.MEMBER_AUS_RAW (unique_id VARCHAR, member_name VARCHAR, tier_type VARCHAR, dob VARCHAR,
    enrollment_date VARCHAR, flight_date VARCHAR, _file_name VARCHAR NOT NULL, _file_row NUMBER NOT NULL, _loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());
CREATE TABLE IF NOT EXISTS RAW.MEMBER_IND_RAW (id VARCHAR, name VARCHAR, dob VARCHAR, tier_code VARCHAR, enrollment_date VARCHAR,
    member_type VARCHAR, flight_date VARCHAR, _file_name VARCHAR NOT NULL, _file_row NUMBER NOT NULL, _loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP());

CREATE TABLE IF NOT EXISTS RAW.REDEMPTION_FEED_RAW (
    payload    VARIANT       NOT NULL,   -- one JSON document per member per feed
    _file_name VARCHAR       NOT NULL,
    _file_row  NUMBER        NOT NULL,
    _loaded_at TIMESTAMP_NTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
);

-- ---------- STG: typed, derived columns, DQ outcome ----------
CREATE TABLE IF NOT EXISTS STG.MEMBER_STG (
    source           VARCHAR(10),        -- PIPE | USA | AUS | IND
    member_key       VARCHAR(30),        -- member_id for PIPE; '<SRC>-<id>' for country extracts (their ids overlap: 1,2,3...)
    member_id        VARCHAR(18),
    member_type      VARCHAR(1),         -- I(ndividual) / C(orporate); only the IND extract carries it
    member_name      VARCHAR(255),
    enrollment_date  DATE,
    last_flight_date DATE,
    tier_code        VARCHAR(5),
    agent_name       VARCHAR(255),
    state            VARCHAR(5),
    country_src      VARCHAR(5),
    country_code     VARCHAR(2),
    post_code        VARCHAR(5),         -- VARCHAR not INT: INT drops leading zeros (e.g. 02134)
    dob              DATE,
    is_active        VARCHAR(1),
    age              NUMBER(3,0),        -- derived, as of feed date
    stale_member     BOOLEAN,            -- derived: days since last flight > 90
    feed_ts          TIMESTAMP_NTZ NOT NULL,  -- extraction timestamp from file name: ordering key for "latest wins"
    dq_status        VARCHAR(8),         -- VALID | WARN | REJECT
    dq_errors        ARRAY,
    _file_name       VARCHAR,
    _file_row        NUMBER
) CLUSTER BY (member_id);

-- ---------- CORE: country tables are created from this template by the split procedure ----------
CREATE TABLE IF NOT EXISTS CORE.MEMBER_TEMPLATE (
    member_key VARCHAR(30) NOT NULL, member_type VARCHAR(1), member_id VARCHAR(18) NOT NULL, member_name VARCHAR(255) NOT NULL, enrollment_date DATE NOT NULL,
    last_flight_date DATE, tier_code VARCHAR(5), agent_name VARCHAR(255), state VARCHAR(5),
    country_code VARCHAR(2) NOT NULL, post_code VARCHAR(5), dob DATE, is_active VARCHAR(1),
    age NUMBER(3,0), stale_member BOOLEAN, feed_ts TIMESTAMP_NTZ NOT NULL,
    updated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT pk_member PRIMARY KEY (member_key)   -- informational in Snowflake; enforced by MERGE + DQ check
);

-- Source of truth for "which country is this member in right now" (avoids scanning every country table)
CREATE TABLE IF NOT EXISTS CORE.MEMBER_COUNTRY_REGISTRY (
    member_key VARCHAR(30) NOT NULL PRIMARY KEY, country_code VARCHAR(2) NOT NULL, feed_ts TIMESTAMP_NTZ NOT NULL
);

-- ---------- CORE: flattened redemptions (one row per transaction) ----------
CREATE TABLE IF NOT EXISTS CORE.REDEMPTION_TXN (
    txn_id VARCHAR NOT NULL PRIMARY KEY, member_id VARCHAR(18) NOT NULL,
    txn_date DATE, partner VARCHAR(100), miles_redeemed NUMBER(12,0), status VARCHAR(20),
    feed_date DATE NOT NULL, _file_name VARCHAR, updated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) CLUSTER BY (member_id);

-- ---------- DQ ----------
CREATE TABLE IF NOT EXISTS DQ.MEMBER_REJECTS AS SELECT * FROM STG.MEMBER_STG WHERE 1=0;
CREATE TABLE IF NOT EXISTS DQ.CHECK_RESULTS (
    run_ts TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), check_name VARCHAR, severity VARCHAR, failed_rows NUMBER, sample VARIANT
);
