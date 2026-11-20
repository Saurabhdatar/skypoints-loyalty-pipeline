"""Flatten the partner JSON redemption feed (mirrors sql/04). Accepts one JSON doc, a JSON array, or NDJSON."""
from __future__ import annotations
import json
from pathlib import Path
import pandas as pd

COLS = ["txn_id", "member_id", "txn_date", "partner", "miles_redeemed", "status", "feed_date"]


def _docs(path: Path) -> list[dict]:
    text = path.read_text(encoding="utf-8-sig").strip()
    try:
        data = json.loads(text)
        return data if isinstance(data, list) else [data]
    except json.JSONDecodeError:  # NDJSON
        return [json.loads(l) for l in text.splitlines() if l.strip()]


def flatten(path: Path) -> pd.DataFrame:
    rows = []
    for doc in _docs(path):
        for tx in doc.get("redemptions") or []:  # members with no redemptions simply yield no rows
            rows.append({"member_id": str(doc.get("member_id", "")).strip(), "feed_date": doc.get("feed_date"), **tx})
    df = pd.DataFrame(rows, columns=COLS)
    df["txn_date"] = pd.to_datetime(df["txn_date"], format="%Y%m%d", errors="coerce")
    df["feed_date"] = pd.to_datetime(df["feed_date"], format="%Y%m%d", errors="coerce")
    df["miles_redeemed"] = pd.to_numeric(df["miles_redeemed"], errors="coerce")
    df["status"] = df["status"].str.upper()
    return df


def validate(df: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    bad = (df["txn_id"].isna() | df["member_id"].eq("") | df["feed_date"].isna() | df["txn_date"].isna()
           | ~(df["miles_redeemed"] > 0) | (df["txn_date"] > df["feed_date"]))
    dup = df.duplicated("txn_id", keep="last")  # same txn in several feeds: newest feed wins
    return df[~bad & ~dup], df[bad]


def join_members(txns: pd.DataFrame, members: dict[str, pd.DataFrame]) -> pd.DataFrame:
    """LEFT join on member_id; orphans stay visible with is_orphan=True."""
    allm = pd.concat(members.values(), ignore_index=True) if members else pd.DataFrame(columns=["member_id", "member_key"])
    allm = allm[allm["member_key"] == allm["member_id"]]  # partner feed uses the global Member_Id, not per-country extract IDs
    cols = ["member_id", "member_name", "tier_code", "country_code", "stale_member", "age"]
    out = txns.merge(allm[cols], on="member_id", how="left", indicator=True)
    out["is_orphan"] = out.pop("_merge").eq("left_only")
    return out
