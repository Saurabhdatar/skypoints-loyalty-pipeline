-- Step 1: land files as-is. Stage @RAW.FEED_STAGE assumed. COPY load history stops a file loading twice.
-- Pipe feed name: SKYPOINTS_MEMBERS_YYYYMMDD_HHMMSSTT.dat   Country extracts: USA.csv / AUS.csv / IND.csv
CREATE FILE FORMAT IF NOT EXISTS RAW.FF_PIPE TYPE=CSV FIELD_DELIMITER='|' SKIP_HEADER=1 TRIM_SPACE=TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY='"' ERROR_ON_COLUMN_COUNT_MISMATCH=FALSE;
CREATE FILE FORMAT IF NOT EXISTS RAW.FF_CSV TYPE=CSV FIELD_DELIMITER=',' SKIP_HEADER=1 TRIM_SPACE=TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY='"' ERROR_ON_COLUMN_COUNT_MISMATCH=FALSE;

COPY INTO RAW.MEMBER_FEED_RAW
FROM (SELECT $2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, CURRENT_TIMESTAMP()
      FROM @RAW.FEED_STAGE)                                    -- $1 empty: records start with '|'
FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_PIPE') PATTERN = '.*MEMBERS.*[.]dat' ON_ERROR = CONTINUE;
COPY INTO RAW.MEMBER_USA_RAW FROM (SELECT $1,$2,$3,$4,$5, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, CURRENT_TIMESTAMP() FROM @RAW.FEED_STAGE)
FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_CSV') PATTERN = '.*USA[.]csv' ON_ERROR = CONTINUE;
COPY INTO RAW.MEMBER_AUS_RAW FROM (SELECT $1,$2,$3,$4,$5,$6, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, CURRENT_TIMESTAMP() FROM @RAW.FEED_STAGE)
FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_CSV') PATTERN = '.*AUS[.]csv' ON_ERROR = CONTINUE;   -- convert .xlsx to CSV upstream
COPY INTO RAW.MEMBER_IND_RAW FROM (SELECT $1,$2,$3,$4,$5,$6,$7, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, CURRENT_TIMESTAMP() FROM @RAW.FEED_STAGE)
FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_CSV') PATTERN = '.*IND[.]csv' ON_ERROR = CONTINUE;

-- One canonical shape over all four sources. Everything is still VARCHAR here.
CREATE OR REPLACE VIEW RAW.V_MEMBER_CANONICAL AS
SELECT 'PIPE' source, member_id, member_name, enrollment_date, last_flight_date, dob, tier_code, agent_name, state,
       country, post_code, is_active, NULL::VARCHAR member_type, _file_name, _file_row
  FROM RAW.MEMBER_FEED_RAW WHERE record_type = 'D'
UNION ALL SELECT 'USA', id, name, enrollment_date, flight_date, NULL, tier_code, NULL, NULL, 'USA', NULL, NULL, NULL, _file_name, _file_row FROM RAW.MEMBER_USA_RAW
UNION ALL SELECT 'AUS', unique_id, member_name, enrollment_date, flight_date, dob, tier_type, NULL, NULL, 'AUS', NULL, NULL, NULL, _file_name, _file_row FROM RAW.MEMBER_AUS_RAW
UNION ALL SELECT 'IND', id, name, enrollment_date, flight_date, dob, tier_code, NULL, NULL, 'IND', NULL, NULL, member_type, _file_name, _file_row FROM RAW.MEMBER_IND_RAW;

-- Date parsing that never throws: '########' (Excel column too narrow when exported), 'NULL', blanks and impossible dates -> NULL.
CREATE OR REPLACE FUNCTION STG.F_PARSE_DATE(V VARCHAR, STYLE VARCHAR) RETURNS DATE AS
$$ CASE
     WHEN NULLIF(TRIM(V),'') IS NULL OR UPPER(TRIM(V)) IN ('NULL','N/A','NA','NONE') OR REGEXP_LIKE(TRIM(V),'#+') THEN NULL
     WHEN STYLE = 'YMD'  THEN TRY_TO_DATE(TRIM(V),'YYYYMMDD')
     WHEN STYLE = 'ISO'  THEN TRY_TO_DATE(LEFT(TRIM(V),10),'YYYY-MM-DD')
     WHEN STYLE = 'DMY8' THEN TRY_TO_DATE(LPAD(TRIM(V),8,'0'),'DDMMYYYY')
     WHEN STYLE = 'DMY'  THEN TRY_TO_DATE(TRIM(V),'DD/MM/YYYY')          -- accepts 1/1/2022 (verify on your account)
     WHEN STYLE = 'MDY'  THEN CASE
          WHEN CONTAINS(V,'/')       THEN TRY_TO_DATE(TRIM(V),'MM/DD/YYYY')
          WHEN LENGTH(TRIM(V)) = 8   THEN TRY_TO_DATE(TRIM(V),'MMDDYYYY')
          WHEN LENGTH(TRIM(V)) = 7   THEN COALESCE(TRY_TO_DATE(LPAD(TRIM(V),8,'0'),'MMDDYYYY'),                       -- M DD YYYY
                                                   TRY_TO_DATE(LEFT(TRIM(V),2) || '0' || SUBSTR(TRIM(V),3),'MMDDYYYY')) -- MM D YYYY
        END
   END $$;
-- 7 digits such as 1052022 can be 1/05/2022 or 10/5/2022. We take the first and flag it (W12) rather than guess silently.
CREATE OR REPLACE FUNCTION STG.F_DATE_AMBIGUOUS(V VARCHAR, STYLE VARCHAR) RETURNS BOOLEAN AS
$$ STYLE = 'MDY' AND NOT CONTAINS(V,'/') AND LENGTH(TRIM(V)) = 7
   AND TRY_TO_DATE(LPAD(TRIM(V),8,'0'),'MMDDYYYY') IS NOT NULL
   AND TRY_TO_DATE(LEFT(TRIM(V),2) || '0' || SUBSTR(TRIM(V),3),'MMDDYYYY') IS NOT NULL $$;

-- Step 2: typed staging + derived Age / Stale_Member + DQ status. Idempotent per file (delete + insert).
-- P_FEED_TS: used when the file name carries no timestamp (country extracts); defaults to now.
-- Policy: bad MANDATORY field (id, name, enrollment date, country) -> REJECT. Bad OPTIONAL field -> value NULL + WARN.
CREATE OR REPLACE PROCEDURE STG.SP_LOAD_MEMBER_STG(P_FILE VARCHAR, P_FEED_TS TIMESTAMP_NTZ)
RETURNS VARCHAR LANGUAGE SQL AS
$$
DECLARE v_feed_ts TIMESTAMP_NTZ;
BEGIN
  v_feed_ts := COALESCE(
      TRY_TO_TIMESTAMP_NTZ(REGEXP_SUBSTR(:P_FILE,'(\\d{8})_(\\d{6})',1,1,'e',1) || REGEXP_SUBSTR(:P_FILE,'(\\d{8})_(\\d{6})',1,1,'e',2),'YYYYMMDDHH24MISS'),
      :P_FEED_TS, CURRENT_TIMESTAMP());
  DELETE FROM STG.MEMBER_STG WHERE _file_name = :P_FILE;

  INSERT INTO STG.MEMBER_STG
  WITH src AS (
    SELECT c.source, NULLIF(TRIM(c.member_id),'') member_id, NULLIF(TRIM(c.member_name),'') member_name,
           STG.F_PARSE_DATE(c.enrollment_date, p.date_style)  enrollment_date,
           STG.F_PARSE_DATE(c.last_flight_date, p.date_style) last_flight_date,
           STG.F_PARSE_DATE(c.dob, p.dob_style)               dob_parsed,
           STG.F_DATE_AMBIGUOUS(c.enrollment_date, p.date_style) OR STG.F_DATE_AMBIGUOUS(c.last_flight_date, p.date_style)
                                                              OR STG.F_DATE_AMBIGUOUS(c.dob, p.dob_style) is_ambiguous,
           c.last_flight_date lf_raw, c.dob dob_raw,
           NULLIF(UPPER(TRIM(c.tier_code)),'') tier_code, NULLIF(TRIM(c.agent_name),'') agent_name,
           NULLIF(UPPER(TRIM(c.state)),'') state, NULLIF(UPPER(TRIM(c.country)),'') country_src,
           NULLIF(TRIM(c.post_code),'') post_code, NULLIF(UPPER(TRIM(c.is_active)),'') is_active,
           NULLIF(UPPER(TRIM(c.member_type)),'') member_type, c._file_name, c._file_row
    FROM RAW.V_MEMBER_CANONICAL c JOIN REF.SOURCE_PROFILE p ON p.source = c.source
    WHERE c._file_name = :P_FILE
  ), d AS (
    SELECT s.*, m.country_code, :v_feed_ts::DATE AS fd,
           (dob_parsed > :v_feed_ts::DATE OR DATEDIFF(year, dob_parsed, :v_feed_ts::DATE) > 120) AS dob_implausible,
           IFF(dob_parsed > :v_feed_ts::DATE OR DATEDIFF(year, dob_parsed, :v_feed_ts::DATE) > 120, NULL, dob_parsed) AS dob
    FROM src s LEFT JOIN REF.COUNTRY_MAP m ON m.source_code = s.country_src
  ), e AS (
    SELECT d.*, ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(member_id IS NULL,'E01_MEMBER_ID_MISSING',NULL),
      IFF(member_id IS NOT NULL AND (NOT REGEXP_LIKE(member_id,'[0-9]+') OR LENGTH(member_id)>18),'E02_MEMBER_ID_FORMAT',NULL),
      IFF(member_name IS NULL,'E03_MEMBER_NAME_MISSING',NULL),
      IFF(enrollment_date IS NULL,'E04_ENROLLMENT_DATE_MISSING_OR_INVALID',NULL),
      IFF(enrollment_date > fd,'E08_ENROLLMENT_IN_FUTURE',NULL),
      IFF(country_src IS NOT NULL AND country_code IS NULL,'E10_UNKNOWN_COUNTRY',NULL),
      IFF(country_src IS NULL,'E11_COUNTRY_MISSING',NULL),
      IFF(LENGTH(member_name)>255 OR LENGTH(agent_name)>255 OR LENGTH(tier_code)>5 OR LENGTH(state)>5
          OR LENGTH(country_src)>5 OR LENGTH(post_code)>5 OR LENGTH(member_id)>18,'E12_FIELD_TOO_LONG',NULL)
    )) errs,
    ARRAY_COMPACT(ARRAY_CONSTRUCT(
      IFF(NULLIF(TRIM(lf_raw),'') IS NOT NULL AND UPPER(TRIM(lf_raw)) NOT IN ('NULL','N/A','NA','NONE') AND last_flight_date IS NULL,'W06_LAST_FLIGHT_DATE_INVALID',NULL),
      IFF(NULLIF(TRIM(dob_raw),'') IS NOT NULL AND UPPER(TRIM(dob_raw)) NOT IN ('NULL','N/A','NA','NONE') AND dob_parsed IS NULL,'W07_DOB_INVALID',NULL),
      IFF(REGEXP_LIKE(TRIM(COALESCE(lf_raw,'')),'#+') OR REGEXP_LIKE(TRIM(COALESCE(dob_raw,'')),'#+'),'W08_EXCEL_OVERFLOW_VALUE',NULL),
      IFF(last_flight_date < enrollment_date,'W09_FLIGHT_BEFORE_ENROLLMENT',NULL),
      IFF(last_flight_date > fd,'W10_FLIGHT_IN_FUTURE',NULL),
      IFF(dob_implausible,'W11_DOB_IMPLAUSIBLE',NULL),
      IFF(is_ambiguous,'W12_DATE_AMBIGUOUS',NULL),
      IFF(is_active IS NOT NULL AND is_active NOT IN ('A','I'),'W01_IS_ACTIVE_UNEXPECTED',NULL),
      IFF(tier_code IS NOT NULL AND tier_code NOT IN ('GLD','SLV','PLT','BRZ'),'W02_TIER_UNEXPECTED',NULL),
      IFF(post_code IS NOT NULL AND NOT REGEXP_LIKE(post_code,'[0-9]+'),'W03_POST_CODE_NON_NUMERIC',NULL),
      IFF(source = 'PIPE' AND member_id IS NOT NULL AND LENGTH(member_id) < 6,'W05_MEMBER_ID_SHORT',NULL),
      IFF(member_type IS NOT NULL AND member_type NOT IN ('I','C'),'W13_MEMBER_TYPE_UNEXPECTED',NULL)
    )) warns
    FROM d)
  SELECT source,
         IFF(source = 'PIPE', member_id, source || '-' || COALESCE(member_id,'')) AS member_key,   -- extracts reuse ids 1,2,3
         member_id, member_type, member_name, enrollment_date, last_flight_date, tier_code, agent_name, state, country_src,
         country_code, post_code, dob, is_active,
         DATEDIFF(year, dob, fd) - IFF(DATE_FROM_PARTS(YEAR(fd),MONTH(dob),DAY(dob)) > fd, 1, 0),   -- exact age
         COALESCE(DATEDIFF(day, last_flight_date, fd) > 90, TRUE),                                 -- no flight = stale
         :v_feed_ts,
         CASE WHEN ARRAY_SIZE(errs)>0 THEN 'REJECT' WHEN ARRAY_SIZE(warns)>0 THEN 'WARN' ELSE 'VALID' END,
         ARRAY_CAT(errs, warns), _file_name, _file_row
  FROM e;
  -- NOTE: the SELECT column order above must match STG.MEMBER_STG; adjust if you reorder the DDL.

  DELETE FROM DQ.MEMBER_REJECTS WHERE _file_name = :P_FILE;   -- quarantine, never silently drop
  INSERT INTO DQ.MEMBER_REJECTS SELECT * FROM STG.MEMBER_STG WHERE _file_name = :P_FILE AND dq_status = 'REJECT';
  RETURN 'loaded ' || :P_FILE;
END;
$$;
