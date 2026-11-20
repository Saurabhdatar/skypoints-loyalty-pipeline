-- Flatten the partner JSON feed (one document per member, array of redemptions) to one row per transaction.
-- Land raw documents first:
--   COPY INTO RAW.REDEMPTION_FEED_RAW FROM (SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, CURRENT_TIMESTAMP()
--   FROM @RAW.FEED_STAGE) FILE_FORMAT=(TYPE=JSON STRIP_OUTER_ARRAY=TRUE) PATTERN='.*redemption.*[.]json';
CREATE OR REPLACE PROCEDURE CORE.SP_LOAD_REDEMPTIONS(P_FILE VARCHAR)
RETURNS VARCHAR LANGUAGE SQL AS
$$
BEGIN
  MERGE INTO CORE.REDEMPTION_TXN t USING (
    SELECT * FROM (
      SELECT TRIM(r.payload:member_id::STRING)                   AS member_id,
             TRIM(f.value:txn_id::STRING)                        AS txn_id,
             TRY_TO_DATE(f.value:txn_date::STRING,'YYYYMMDD')    AS txn_date,
             f.value:partner::STRING                             AS partner,
             TRY_TO_NUMBER(f.value:miles_redeemed::STRING)       AS miles_redeemed,
             UPPER(f.value:status::STRING)                       AS status,
             TRY_TO_DATE(r.payload:feed_date::STRING,'YYYYMMDD') AS feed_date,
             r._file_name AS _file_name, r._file_row AS _file_row
      FROM RAW.REDEMPTION_FEED_RAW r, LATERAL FLATTEN(INPUT => r.payload:redemptions) f
      WHERE r._file_name = :P_FILE)
    WHERE txn_id IS NOT NULL AND member_id IS NOT NULL AND miles_redeemed > 0 AND feed_date IS NOT NULL
    -- the same txn can reappear in later daily feeds (PENDING -> COMPLETED): newest feed wins
    QUALIFY ROW_NUMBER() OVER (PARTITION BY txn_id ORDER BY feed_date DESC, _file_row DESC) = 1
  ) s ON t.txn_id = s.txn_id
  WHEN MATCHED AND s.feed_date >= t.feed_date THEN UPDATE SET
       member_id=s.member_id, txn_date=s.txn_date, partner=s.partner, miles_redeemed=s.miles_redeemed,
       status=s.status, feed_date=s.feed_date, _file_name=s._file_name, updated_at=CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (txn_id,member_id,txn_date,partner,miles_redeemed,status,feed_date,_file_name)
       VALUES (s.txn_id,s.member_id,s.txn_date,s.partner,s.miles_redeemed,s.status,s.feed_date,s._file_name);
  RETURN 'ok';
END;
$$;

-- Join back to member profile: redemption member_id = member_key (VARCHAR both sides; JSON ids arrive as strings).
-- Extract members have keys like 'USA-1', so they can never be matched by accident to partner member 1.
-- LEFT JOIN so redemptions for members not yet loaded stay visible as orphans instead of vanishing.
CREATE OR REPLACE VIEW CORE.V_MEMBER_REDEMPTIONS AS
SELECT x.txn_id, x.txn_date, x.partner, x.miles_redeemed, x.status, x.feed_date,
       x.member_id, m.member_name, m.tier_code, m.country_code, m.stale_member, m.age,
       (m.member_id IS NULL) AS is_orphan
FROM CORE.REDEMPTION_TXN x
LEFT JOIN CORE.V_MEMBER_ALL m ON m.member_key = x.member_id;   -- partner feed uses the global Member_Id = PIPE member_key
-- Country-scoped queries at scale: join CORE.MEMBER_COUNTRY_REGISTRY first, then a single country table.
-- Only status = 'COMPLETED' miles should count toward balances.
