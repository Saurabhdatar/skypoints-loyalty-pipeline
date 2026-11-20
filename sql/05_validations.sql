-- Post-load checks. The orchestrator writes counts to DQ.CHECK_RESULTS and fails the run on ERROR severity.
-- 1. [ERROR] Mandatory fields never leak into CORE (rejected at staging with E01/E03/E04/E11)
SELECT 'mandatory_core' chk, COUNT(*) failed FROM CORE.V_MEMBER_ALL
WHERE member_key IS NULL OR member_name IS NULL OR enrollment_date IS NULL OR country_code IS NULL;

-- 2. [ERROR] Key uniqueness: member_key unique across ALL country tables (a member lives in exactly one)
SELECT member_key, COUNT(*) c FROM CORE.V_MEMBER_ALL GROUP BY member_key HAVING c > 1;
-- 2a. [INFO] raw ids reused by different people in different sources (USA/AUS/IND all use 1,2,3): why member_key exists
SELECT member_id, COUNT(DISTINCT source) srcs, COUNT(DISTINCT member_name) names FROM STG.MEMBER_STG
  WHERE dq_status <> 'REJECT' GROUP BY 1 HAVING srcs > 1 AND names > 1;
-- 2b. [ERROR] Registry agrees with country tables
SELECT r.member_key FROM CORE.MEMBER_COUNTRY_REGISTRY r LEFT JOIN CORE.V_MEMBER_ALL m
  ON m.member_key = r.member_key AND m.country_code = r.country_code WHERE m.member_key IS NULL;
-- 2c. The spec marks Member Name as the key column. Names are not unique, so Member_Id is used as the business key
--     (raise with the stakeholder). Informational: names shared by different members.
SELECT member_name, COUNT(DISTINCT member_id) FROM CORE.V_MEMBER_ALL GROUP BY 1 HAVING COUNT(DISTINCT member_id) > 1;

-- 3. [WARN] Duplicates inside one file (resolved by latest-wins)
SELECT _file_name, member_id, COUNT(*) FROM STG.MEMBER_STG GROUP BY 1,2 HAVING COUNT(*) > 1;

-- 4. Issues visible in the sample data
--  a) inconsistent country codes (USA/US, AU vs AUS, PHIL): normalised via REF.COUNTRY_MAP; unknown -> E10 reject
SELECT country_src, COUNT(*) FROM STG.MEMBER_STG WHERE country_code IS NULL GROUP BY 1;
--  b) DOB lost its leading zero (3051985 vs 03051985): repaired with LPAD; DDMMYYYY vs MMDDYYYY ambiguity -> confirm with owner
SELECT LENGTH(dob) dob_len, COUNT(*) FROM RAW.MEMBER_FEED_RAW WHERE record_type='D' GROUP BY 1;
--  c) member_id shorter than peers (22345, 2256 vs 223457): W05 for profiling
SELECT LENGTH(member_id) len, COUNT(*) FROM STG.MEMBER_STG GROUP BY 1 ORDER BY 1;
--  d) Agent_Name blank/shifted in sample rows -> W04; column-count mismatches surface via COPY VALIDATE()
SELECT * FROM TABLE(VALIDATE(RAW.MEMBER_FEED_RAW, JOB_ID => '_last'));
--  e) Post_Code in spec but absent from the layout and sample; INT would drop leading zeros -> VARCHAR(5)
--  f) Header says Is_Active / Country, staging says FLAG / County: mapping documented in the README
--  g) flight before enrollment, future dates, age > 120 -> W09 / W10 / W11 (optional fields are nulled, member kept)
--  h) real extracts: '########' cells (Excel column too narrow when exported; real value lost) -> W08. If a MANDATORY
--     field is '########' the row is rejected (E04). Ask the sender to re-export, don't guess.
SELECT source, COUNT(*) FROM STG.MEMBER_STG WHERE ARRAY_CONTAINS('W08_EXCEL_OVERFLOW_VALUE'::VARIANT, dq_errors) GROUP BY 1;
--  i) impossible calendar dates (AUS 2021-13-13) -> E04; ambiguous 7-digit USA dates (1052022) -> W12
SELECT source, dq_errors, COUNT(*) FROM STG.MEMBER_STG WHERE dq_status <> 'VALID' GROUP BY 1,2 ORDER BY 3 DESC;

-- 5. Redemptions
SELECT COUNT(*) orphan_txns FROM CORE.V_MEMBER_REDEMPTIONS WHERE is_orphan;               -- [WARN]
SELECT status, COUNT(*) FROM CORE.REDEMPTION_TXN GROUP BY 1;                              -- expect COMPLETED / PENDING
SELECT * FROM CORE.REDEMPTION_TXN WHERE miles_redeemed <= 0 OR txn_date > feed_date;      -- [ERROR]

-- 6. [ERROR] Volume/freshness: file landed, header present, row count within +-50% of 7-day average
