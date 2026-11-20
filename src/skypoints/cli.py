"""python -m skypoints.cli --input data/sample --out out [--as-of 2024-01-15]"""
from __future__ import annotations
import argparse, json
from pathlib import Path
import pandas as pd
from . import members, redemptions


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=Path("out"))
    ap.add_argument("--as-of", type=pd.Timestamp, default=None, help="reference date for Age/Stale (default: file feed date)")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)

    mfiles = sorted(p for p in a.input.iterdir() if p.suffix.lower() in {".dat", ".txt", ".csv", ".xlsx", ".psv"})
    res = members.run(mfiles, a.as_of)
    for name, df in res["tables"].items():
        df.to_csv(a.out / f"{name.lower()}.csv", index=False)
    res["rejects"].to_csv(a.out / "member_rejects.csv", index=False)
    summary = {"files": [p.name for p in mfiles], "rows_in": len(res["staged"]), "rejected": len(res["rejects"]),
               "dq_status": res["staged"]["dq_status"].value_counts().to_dict(),
               "rows_per_table": {k: len(v) for k, v in res["tables"].items()}, "moved_members": res["moved_members"], "id_collisions": res["id_collisions"]}

    jfiles = sorted(a.input.glob("*.json"))
    if jfiles:
        txns = pd.concat([redemptions.flatten(p) for p in jfiles], ignore_index=True)
        ok, bad = redemptions.validate(txns)
        joined = redemptions.join_members(ok, res["tables"])
        ok.to_csv(a.out / "redemption_txn.csv", index=False)
        bad.to_csv(a.out / "redemption_rejects.csv", index=False)
        joined.to_csv(a.out / "member_redemptions.csv", index=False)
        summary.update(redemptions=len(ok), redemption_rejects=len(bad), orphan_redemptions=int(joined["is_orphan"].sum()))
    (a.out / "dq_summary.json").write_text(json.dumps(summary, indent=2, default=str))
    print(json.dumps(summary, indent=2, default=str))


if __name__ == "__main__":
    main()
