#!/usr/bin/env bash
# Creates incremental commits so reviewers can see how the solution evolved.
set -e
git init -q 2>/dev/null || true
c() { git add "${@:2}"; git commit -q -m "$1"; echo "committed: $1"; }
c "chore: project scaffold and gitignore" .gitignore
c "feat(ddl): raw, staging, country template, registry and DQ tables" sql/01_ddl.sql
c "feat(staging): per-source profiles, safe date parsing, Age, Stale_Member and DQ codes" sql/02_load_staging.sql
c "feat(split): latest-wins country split keyed by member_key, handles country moves" sql/03_country_split.sql
c "feat(redemptions): flatten partner JSON and join back to members" sql/04_redemptions.sql
c "feat(dq): post-load validation queries" sql/05_validations.sql
c "feat(py): reference implementation with USA/AUS/IND profiles, DQ, latest-wins and split" src/skypoints/__init__.py src/skypoints/config.py src/skypoints/members.py
c "feat(py): redemption flattening and CLI" src/skypoints/redemptions.py src/skypoints/cli.py
c "test: sample feeds, real extract fixtures and unit tests" data tests
c "docs: README with design decisions, data issues and assumptions" README.md
