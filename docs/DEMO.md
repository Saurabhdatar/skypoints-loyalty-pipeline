# Live demo script (about 10 minutes)

1. **Problem and shape (1 min).** Open the README architecture diagram: RAW (text) -> STG (typed, DQ) -> CORE country tables.
2. **Run it (2 min).** `make run`, then open `out/`:
   - `table_usa.csv`, `table_india.csv`, `table_australia.csv`: split per country.
   - `member_rejects.csv`: each rejected row with its reason code.
   - `dq_summary.json`: counts, `moved_members`, `id_collisions`.
3. **The interesting data (3 min).** Show `data/sample/`: USA unpadded dates, AUS `2021-13-13` and `NULL`, IND `########`.
   Explain optional vs mandatory handling and why IDs 1,2,3 overlap, hence `member_key`.
4. **Latest wins (2 min).** Ravi (223458) is in IND on day 1 and USA on day 2. Show him only in `table_usa.csv`.
   Then `make test` and point at `test_older_file_cannot_overwrite_newer`.
5. **Snowflake and scale (2 min).** Walk through `sql/03_country_split.sql`: batch -> movers -> delete from old table -> MERGE ->
   registry. Say why the registry avoids scanning N tables, and why MERGE keeps replays idempotent.

Questions to expect, with short answers
- *Why VARCHAR in RAW?* So a bad value can never fail the load; it gets quarantined with a reason.
- *Why not reject a row with a bad DOB?* Optional field: null it and warn; losing a member over it is worse.
- *What would you do next?* Snowpipe/Tasks orchestration, row-count anomaly check, dbt tests, run the SQL in a real account.
