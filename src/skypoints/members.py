"""Parse -> validate -> derive -> latest-wins -> split. Mirrors sql/02 and sql/03.

Two kinds of source: the daily pipe-delimited feed (PIPE, global Member_Id) and per-country extracts
(USA/AUS/IND files, each with its own layout and its own ID series).
"""
from __future__ import annotations
import re
from datetime import datetime
from pathlib import Path
import pandas as pd
from . import config as C

ALL_COLS = C.MEMBER_COLUMNS + C.EXTRA_COLUMNS
DATE_COLS = ["enrollment_date", "last_flight_date", "dob"]


def _canon(col: str) -> str:
    c = re.sub(r"[^a-z0-9]+", "_", str(col).strip().lower()).strip("_")
    return C.ALIASES.get(c, c)


def feed_ts_from_name(name: str) -> pd.Timestamp:
    """SKYPOINTS_MEMBERS_YYYYMMDD_HHMMSSTT.dat -> timestamp; NaT when the name carries no date."""
    m = re.search(r"(\d{8})[_-]?(\d{6})?", name)
    if not m:
        return pd.NaT
    return pd.to_datetime(m.group(1) + (m.group(2) or "000000"), format="%Y%m%d%H%M%S", errors="coerce")


# ----------------------------------------------------------------------------- dates
def _strptime(fmt: str, v: str):
    try:
        return datetime.strptime(v, fmt)
    except ValueError:
        return None


def parse_date(value, style: str) -> tuple[pd.Timestamp, bool]:
    """-> (date or NaT, ambiguous). Never raises: unparseable / '########' / 'NULL' all become NaT."""
    if value is None or pd.isna(value):
        return pd.NaT, False
    v = re.sub(r"[ T]00:00:00$", "", str(value).strip())
    if v == "" or v.upper() in C.NULL_TOKENS or re.fullmatch(r"#+", v):
        return pd.NaT, False
    if style == "YMD":
        cands = [_strptime("%Y%m%d", v)]
    elif style == "ISO":
        cands = [_strptime("%Y-%m-%d", v)]
    elif style == "DMY8":                     # DDMMYYYY, leading zero lost in staging (3051985)
        cands = [_strptime("%d%m%Y", v.zfill(8))]
    elif style == "DMY":
        cands = [_strptime("%d/%m/%Y", v)]
    elif style == "MDY":
        if "/" in v:
            cands = [_strptime("%m/%d/%Y", v)]
        elif len(v) == 8:
            cands = [_strptime("%m%d%Y", v)]
        elif len(v) == 7:                     # M DD YYYY  or  MM D YYYY
            cands = [_strptime("%m%d%Y", "0" + v), _strptime("%m%d%Y", v[:2] + "0" + v[2:])]
        else:
            cands = [None]
    else:
        raise ValueError(f"unknown date style {style}")
    ok = [c for c in cands if c is not None]
    if not ok:
        return pd.NaT, False
    return pd.Timestamp(ok[0]), len(ok) > 1 and ok[0] != ok[1]


def _looks_overflow(s: pd.Series) -> pd.Series:
    return s.astype("string").str.strip().str.fullmatch(r"#+").fillna(False)


# ----------------------------------------------------------------------------- readers
def parse_pipe_file(path: Path) -> pd.DataFrame:
    """|H|...| header and |D|...| detail. Rows with the wrong field count are kept and flagged, not dropped."""
    out = []
    with open(path, encoding="utf-8-sig") as fh:
        for n, line in enumerate(fh, start=1):
            line = line.rstrip("\r\n")
            if not line.startswith("|D|"):
                continue
            parts = [p.strip() for p in line.split("|")[2:]]
            if parts and parts[-1] == "":
                parts = parts[:-1]
            bad = len(parts) not in (10, 11)  # spec layout has 10 fields, spec table 11 (Post Code)
            if len(parts) == 10:
                parts = parts[:8] + [""] + parts[8:]
            parts = (parts + [""] * 11)[:11]
            out.append(dict(zip(C.MEMBER_COLUMNS, parts), member_type="", _file_row=n, _bad_field_count=bad))
    df = pd.DataFrame(out, columns=ALL_COLS + ["_file_row", "_bad_field_count"])
    df["source"] = "PIPE"
    return df


def parse_extract(path: Path) -> pd.DataFrame:
    """Per-country extract (CSV/XLSX, header row). Country comes from the file name (USA.csv -> USA)."""
    source = path.stem.upper()
    if source not in C.PROFILES:
        raise ValueError(f"{path.name}: no source profile for '{source}' (known: {sorted(C.PROFILES)})")
    df = pd.read_excel(path, dtype=str) if path.suffix.lower() in {".xlsx", ".xls"} else pd.read_csv(path, dtype=str, keep_default_na=False)
    df.columns = [_canon(c) for c in df.columns]
    df = df.fillna("")
    for col in ALL_COLS:
        if col not in df:
            df[col] = ""
    df["country"] = source
    df["_file_row"] = range(2, len(df) + 2)
    df["_bad_field_count"] = False
    df["source"] = source
    return df[ALL_COLS + ["_file_row", "_bad_field_count", "source"]]


def load_file(path: Path) -> pd.DataFrame:
    df = parse_pipe_file(path) if path.suffix.lower() in {".dat", ".txt", ".psv"} else parse_extract(path)
    df["_file_name"] = path.name
    ts = feed_ts_from_name(path.name)
    if pd.isna(ts):  # extracts carry no date in the name: use file modification time
        ts = pd.Timestamp(path.stat().st_mtime, unit="s")
    df["feed_ts"] = ts
    return df


# ----------------------------------------------------------------------------- staging
def _blank_to_na(s: pd.Series) -> pd.Series:
    s = s.astype("string").str.strip()
    return s.mask((s == "") | s.str.upper().isin(C.NULL_TOKENS))


def stage(raw: pd.DataFrame, as_of: pd.Timestamp | None = None) -> pd.DataFrame:
    """Typed staging with derived Age / Stale_Member and DQ status (VALID | WARN | REJECT).
    Policy: problems in mandatory fields (id, name, enrollment date, country) reject the row;
    problems in optional fields null the value and raise a warning, so a member is never lost over a bad DOB."""
    r = raw.reset_index(drop=True).copy()
    if "member_type" not in r:
        r["member_type"] = ""
    if "source" not in r:
        r["source"] = "PIPE"
    df = r.copy()
    for c in ALL_COLS:
        df[c] = _blank_to_na(r[c])
    df["country_src"] = df["country"].str.upper()
    df["country_code"] = df["country_src"].map(C.COUNTRY_MAP)
    for c in ("tier_code", "state", "is_active", "member_type"):
        df[c] = df[c].str.upper()

    ambiguous = pd.Series(False, index=df.index)
    overflow = pd.Series(False, index=df.index)
    present_but_bad = {}
    for col in DATE_COLS:
        parsed = [parse_date(v, C.PROFILES[s][col]) for v, s in zip(r[col], r["source"])]
        df[col] = pd.to_datetime(pd.Series([p[0] for p in parsed]))
        ambiguous |= pd.Series([p[1] for p in parsed])
        overflow |= _looks_overflow(r[col])
        present_but_bad[col] = _blank_to_na(r[col]).notna() & df[col].isna()

    fd = df["feed_ts"].dt.normalize() if as_of is None else pd.Series(pd.Timestamp(as_of).normalize(), index=df.index)
    implausible = (df["dob"] > fd) | ((fd.dt.year - df["dob"].dt.year) > 120)
    df.loc[implausible.fillna(False), "dob"] = pd.NaT
    had_bday = (fd.dt.month > df["dob"].dt.month) | ((fd.dt.month == df["dob"].dt.month) & (fd.dt.day >= df["dob"].dt.day))
    df["age"] = (fd.dt.year - df["dob"].dt.year - (~had_bday).astype(int)).astype("Int64").where(df["dob"].notna())
    days = (fd - df["last_flight_date"]).dt.days
    df["stale_member"] = (days > C.STALE_DAYS) | days.isna()  # no flight on record counts as stale

    errs, warns = [], []

    def rule(flag, code, bucket):
        bucket.append(pd.Series(flag.fillna(False).astype(bool).map({True: code, False: ""}), index=df.index))

    rule(df["member_id"].isna(), "E01_MEMBER_ID_MISSING", errs)
    rule(df["member_id"].notna() & ~df["member_id"].fillna("").str.fullmatch(r"\d{1,18}"), "E02_MEMBER_ID_FORMAT", errs)
    rule(df["member_name"].isna(), "E03_MEMBER_NAME_MISSING", errs)
    rule(df["enrollment_date"].isna(), "E04_ENROLLMENT_DATE_MISSING_OR_INVALID", errs)
    rule(df["enrollment_date"] > fd, "E08_ENROLLMENT_IN_FUTURE", errs)
    rule(df["country_src"].notna() & df["country_code"].isna(), "E10_UNKNOWN_COUNTRY", errs)
    rule(df["country_src"].isna(), "E11_COUNTRY_MISSING", errs)
    too_long = pd.Series(False, index=df.index)
    for col, n in C.MAX_LEN.items():
        too_long |= df[col].str.len().fillna(0) > n
    rule(too_long, "E12_FIELD_TOO_LONG", errs)
    rule(df["_bad_field_count"], "E13_FIELD_COUNT_MISMATCH", errs)

    rule(present_but_bad["last_flight_date"], "W06_LAST_FLIGHT_DATE_INVALID", warns)
    rule(present_but_bad["dob"], "W07_DOB_INVALID", warns)
    rule(overflow, "W08_EXCEL_OVERFLOW_VALUE", warns)        # '########': column too narrow when exported, real value lost
    rule(df["last_flight_date"] < df["enrollment_date"], "W09_FLIGHT_BEFORE_ENROLLMENT", warns)
    rule(df["last_flight_date"] > fd, "W10_FLIGHT_IN_FUTURE", warns)
    rule(implausible, "W11_DOB_IMPLAUSIBLE", warns)
    rule(ambiguous, "W12_DATE_AMBIGUOUS", warns)
    rule(df["is_active"].notna() & ~df["is_active"].isin(C.KNOWN_ACTIVE), "W01_IS_ACTIVE_UNEXPECTED", warns)
    rule(df["tier_code"].notna() & ~df["tier_code"].isin(C.KNOWN_TIERS), "W02_TIER_UNEXPECTED", warns)
    rule(df["post_code"].notna() & ~df["post_code"].fillna("").str.fullmatch(r"\d+"), "W03_POST_CODE_NON_NUMERIC", warns)
    rule(df["member_id"].notna() & (df["member_id"].str.len() < 6) & (df["source"] == "PIPE"), "W05_MEMBER_ID_SHORT", warns)
    rule(df["member_type"].notna() & ~df["member_type"].isin(C.KNOWN_MEMBER_TYPES), "W13_MEMBER_TYPE_UNEXPECTED", warns)

    join = lambda cols: pd.concat(cols, axis=1).apply(lambda row: [x for x in row if x], axis=1)
    df["errors"], df["warnings"] = join(errs), join(warns)
    df["dq_status"] = ["REJECT" if e else ("WARN" if w else "VALID") for e, w in zip(df["errors"], df["warnings"])]
    df["dq_errors"] = (df["errors"] + df["warnings"]).map(";".join)
    # Per-country extracts have their own ID series (1,2,3 in every file): namespace them so people don't merge.
    df["member_key"] = df["member_id"].where(df["source"] == "PIPE", df["source"] + "-" + df["member_id"].fillna(""))
    return df.drop(columns=["country", "errors", "warnings", "_bad_field_count"])


def latest_wins(df: pd.DataFrame) -> pd.DataFrame:
    """One row per member_key: newest (feed_ts, file name, file row) wins, which also resolves country moves."""
    ordered = df.sort_values(["feed_ts", "_file_name", "_file_row"], kind="stable")
    return ordered.drop_duplicates("member_key", keep="last")


def id_collisions(good: pd.DataFrame) -> list[str]:
    """Raw IDs that appear in more than one source with different names: proves IDs are not globally unique."""
    g = good.groupby("member_id").agg(n_sources=("source", "nunique"), n_names=("member_name", "nunique"))
    return sorted(g[(g.n_sources > 1) & (g.n_names > 1)].index)


def split_by_country(current: pd.DataFrame) -> dict[str, pd.DataFrame]:
    return {C.TABLE_NAMES[cc]: g.drop(columns=["_file_row"]).reset_index(drop=True) for cc, g in current.groupby("country_code")}


def run(paths: list[Path], as_of: pd.Timestamp | None = None) -> dict:
    staged = stage(pd.concat([load_file(p) for p in paths], ignore_index=True), as_of)
    rejects = staged[staged["dq_status"] == "REJECT"]
    good = staged[staged["dq_status"] != "REJECT"]
    current = latest_wins(good)
    n_ctry = good.groupby("member_key")["country_code"].nunique()
    return {"staged": staged, "rejects": rejects, "tables": split_by_country(current),
            "moved_members": sorted(n_ctry[n_ctry > 1].index), "id_collisions": id_collisions(good)}
