import sys, tempfile, unittest
from pathlib import Path
import pandas as pd
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from skypoints import members, redemptions  # noqa: E402

SAMPLE = Path(__file__).resolve().parents[1] / "data" / "sample"


class MemberTests(unittest.TestCase):
    def run_sample(self, **kw):
        files = sorted(SAMPLE.glob("*.dat"))
        return members.run(files, **kw)

    def test_country_codes_normalised(self):
        s = members.stage(members.load_file(SAMPLE / "SKYPOINTS_MEMBERS_20240115_09300000.dat"))
        self.assertEqual(sorted(s.country_code), ["AU", "CA", "IN", "PH", "US"])

    def test_dob_leading_zero_repaired(self):
        raw = pd.DataFrame([dict(zip(members.C.MEMBER_COLUMNS, ["A", "100001", "20100101", "", "", "", "", "USA", "", "3051985", "A"]),
                                  _file_row=1, _bad_field_count=False, feed_ts=pd.Timestamp("2024-01-15"))])
        s = members.stage(raw)
        self.assertEqual(s.dob.iloc[0], pd.Timestamp("1985-05-03"))
        self.assertEqual(int(s.age.iloc[0]), 38)  # birthday (3 May) not reached on 15 Jan 2024

    def test_stale_flag_boundary(self):
        base = dict(zip(members.C.MEMBER_COLUMNS, ["A", "100001", "20100101", "", "GLD", "x", "CA", "USA", "", "01011990", "A"]),
                    _file_row=1, _bad_field_count=False, feed_ts=pd.Timestamp("2024-04-10"))
        rows = []
        for i, d in enumerate(["20240111", "20240110", "20240109"]):  # 90, 91, 92 days before 2024-04-10 (leap year)
            rows.append({**base, "member_id": f"10000{i}", "last_flight_date": d})
        s = members.stage(pd.DataFrame(rows))
        self.assertEqual(list(s.stale_member), [False, True, True])

    def test_latest_record_wins_when_member_moves_country(self):
        res = self.run_sample()
        self.assertEqual(res["moved_members"], ["223458"])
        self.assertNotIn("223458", set(res["tables"]["TABLE_INDIA"].member_id) if "TABLE_INDIA" in res["tables"] else set())
        usa = res["tables"]["TABLE_USA"]
        ravi = usa[usa.member_id == "223458"].iloc[0]
        self.assertEqual(ravi.tier_code, "PLT")

    def test_older_file_cannot_overwrite_newer(self):
        files = sorted(SAMPLE.glob("*.dat"), reverse=True)  # processed out of order
        res = members.run(files)
        self.assertEqual(res["tables"]["TABLE_USA"].query("member_id=='223458'").iloc[0].tier_code, "PLT")

    def test_rejects_are_quarantined_not_dropped(self):
        res = self.run_sample()
        reasons = " ".join(res["rejects"].dq_errors)
        for code in ("E01_MEMBER_ID_MISSING", "E04_", "E10_UNKNOWN_COUNTRY", "E13_FIELD_COUNT_MISMATCH"):
            self.assertIn(code, reasons)
        self.assertEqual(len(res["staged"]), len(res["rejects"]) + sum(len(t) for t in res["tables"].values()) + 1)  # +1 superseded Ravi row

    def test_member_id_unique_across_country_tables(self):
        res = self.run_sample()
        ids = pd.concat(res["tables"].values()).member_id
        self.assertTrue(ids.is_unique)

    def test_short_ids_warn_not_reject(self):
        s = members.stage(members.load_file(SAMPLE / "SKYPOINTS_MEMBERS_20240115_09300000.dat"))
        short = s[s.member_id.isin(["22345", "2256"])]
        self.assertTrue((short.dq_status == "WARN").all())


class ExtractTests(unittest.TestCase):
    """The three real country extracts: USA.csv (M/D/Y digits), AUS.xlsx (ISO), IND.csv (D/M/Y, Excel '########')."""
    AS_OF = pd.Timestamp("2024-01-15")

    def res(self):
        return members.run([SAMPLE / "USA.csv", SAMPLE / "AUS.xlsx", SAMPLE / "IND.csv"], self.AS_OF)

    def test_usa_unpadded_dates(self):
        s = members.stage(members.load_file(SAMPLE / "USA.csv"), self.AS_OF).set_index("member_id")
        self.assertEqual(s.loc["1", "enrollment_date"], pd.Timestamp("2022-06-15"))
        self.assertEqual(s.loc["3", "enrollment_date"], pd.Timestamp("2021-12-28"))

    def test_usa_seven_digit_date_is_flagged_ambiguous(self):
        s = members.stage(members.load_file(SAMPLE / "USA.csv"), self.AS_OF).set_index("member_id")
        self.assertIn("W12_DATE_AMBIGUOUS", s.loc["2", "dq_errors"])
        self.assertNotIn("W12", s.loc["1", "dq_errors"])  # 6152022 can only be 6/15/2022

    def test_aus_month_13_rejected(self):
        r = self.res()["rejects"]
        row = r[(r.source == "AUS") & (r.member_id == "2")].iloc[0]
        self.assertIn("E04_ENROLLMENT_DATE_MISSING_OR_INVALID", row.dq_errors)

    def test_aus_null_dob_is_not_an_error(self):
        s = members.stage(members.load_file(SAMPLE / "AUS.xlsx"), self.AS_OF).set_index("member_id")
        self.assertEqual(s.loc["1", "dq_status"], "VALID")

    def test_excel_overflow_flagged_but_member_kept(self):
        s = members.stage(members.load_file(SAMPLE / "IND.csv"), self.AS_OF).set_index("member_id")
        self.assertEqual(s.loc["1", "dq_status"], "WARN")
        self.assertIn("W08_EXCEL_OVERFLOW_VALUE", s.loc["1", "dq_errors"])
        self.assertEqual(s.loc["1", "member_type"], "I")

    def test_ind_enrollment_is_day_first(self):
        s = members.stage(members.load_file(SAMPLE / "IND.csv"), self.AS_OF).set_index("member_id")
        self.assertEqual(s.loc["2", "enrollment_date"], pd.Timestamp("2022-05-03"))  # 3/5/2022 = 3 May

    def test_overlapping_ids_do_not_merge_across_countries(self):
        res = self.res()
        self.assertEqual(res["id_collisions"], ["1", "2", "3"])
        keys = pd.concat(res["tables"].values()).member_key
        self.assertTrue(keys.is_unique)
        self.assertEqual(len(keys), 7)  # 3 USA + 2 AUS + 2 IND, nobody overwritten
        self.assertEqual(res["moved_members"], [])

    def test_country_comes_from_file_name(self):
        self.assertEqual(set(self.res()["tables"]), {"TABLE_USA", "TABLE_AUSTRALIA", "TABLE_INDIA"})


class RedemptionTests(unittest.TestCase):
    def test_flatten_and_join(self):
        txns = redemptions.flatten(SAMPLE / "redemptions_20240115.json")
        self.assertEqual(len(txns), 3)
        ok, bad = redemptions.validate(txns)
        self.assertEqual(len(bad), 0)
        res = members.run(sorted(SAMPLE.glob("*.dat")))
        j = redemptions.join_members(ok, res["tables"])
        self.assertEqual(j.set_index("txn_id").loc["RX10093", "is_orphan"], True)
        self.assertEqual(j.set_index("txn_id").loc["RX10091", "country_code"], "US")

    def test_invalid_miles_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "r.json"
            p.write_text('{"member_id":"1","feed_date":"20240115","redemptions":[{"txn_id":"X","txn_date":"20240110","partner":"p","miles_redeemed":-5,"status":"completed"}]}')
            ok, bad = redemptions.validate(redemptions.flatten(p))
            self.assertEqual((len(ok), len(bad)), (0, 1))


if __name__ == "__main__":
    unittest.main()
