#!/usr/bin/env python3
"""Write the SQL that seeds Crucible's rows of the mako table chat_aliases.

Crucible's hosted features (What to Watch, and Previously On written from episode descriptions) call three aliases of
Midgar's shared model service. An alias row holds the instructions and the shape of the reply, so the app sends only
a person's sentence and the titles to choose among. The rows are data, inserted by the operator and never by a
migration: aliases.json names each alias with its limits and reply schema, and prompts/<alias>.txt holds its
instructions. The SQL is idempotent: running it again updates the rows.

Usage:
    python3 -I tools/ai/gen_alias_sql.py > crucible-aliases.sql
    python3 -I tools/ai/gen_alias_sql.py --check
Apply, on the machine that deploys mako:
    npx wrangler@4.149.0 d1 execute openai-image-proxy --remote --file crucible-aliases.sql
"""

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
EM_DASH = "—"
COLUMNS = [
    "app_id", "alias", "model", "system_prompt", "response_schema", "max_tokens", "temperature", "flat_credits",
    "weekly_free", "premium_bypass", "daily_limit", "reasoning", "version",
]


def sql_string(value):
    return "'" + value.replace("'", "''") + "'"


def problems(catalog):
    found = []
    seen = set()
    for entry in catalog["aliases"]:
        name = entry["alias"]
        if name in seen:
            found.append(f"{name} is listed twice")
        seen.add(name)
        path = HERE / "prompts" / f"{name}.txt"
        if not path.is_file():
            found.append(f"{path} is missing")
            continue
        text = path.read_text(encoding="utf-8")
        if EM_DASH in text:
            found.append(f"{path} contains an em dash")
        if not text.strip():
            found.append(f"{path} is empty")
        schema = entry["response_schema"]
        if schema.get("type") != "object" or schema.get("additionalProperties") is not False:
            found.append(f"{name}: the reply schema must be a closed object")
        if sorted(schema.get("required", [])) != sorted(schema.get("properties", {})):
            found.append(f"{name}: every property of the reply must be required")
        if entry.get("reasoning") not in (None, "low", "medium", "high"):
            found.append(f"{name}: reasoning must be low, medium or high when it is set")
        for limit in ("max_tokens", "weekly_free", "daily_limit", "flat_credits", "version"):
            if not isinstance(entry.get(limit), int) or entry[limit] < 0:
                found.append(f"{name}: {limit} must be a whole number")
    for path in sorted((HERE / "prompts").glob("*.txt")):
        if path.stem not in seen:
            found.append(f"{path} belongs to no alias in aliases.json")
    return found


def row(catalog, entry):
    prompt = (HERE / "prompts" / f"{entry['alias']}.txt").read_text(encoding="utf-8").strip()
    schema = json.dumps(entry["response_schema"], separators=(",", ":"), ensure_ascii=False)
    values = [
        sql_string(catalog["app_id"]), sql_string(entry["alias"]), sql_string(catalog["model"]), sql_string(prompt),
        sql_string(schema), str(entry["max_tokens"]), "NULL", str(entry["flat_credits"]), str(entry["weekly_free"]),
        "1" if entry["premium_bypass"] else "0", str(entry["daily_limit"]),
        sql_string(entry["reasoning"]) if entry.get("reasoning") else "NULL", str(entry["version"]),
    ]
    updates = ", ".join(f"{column} = excluded.{column}" for column in COLUMNS[2:])
    return (
        f"INSERT INTO chat_aliases ({', '.join(COLUMNS)})\nVALUES ({', '.join(values)})\n"
        f"ON CONFLICT(app_id, alias) DO UPDATE SET {updates};\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="validate the catalog and the prompts, write nothing")
    arguments = parser.parse_args()
    catalog = json.loads((HERE / "aliases.json").read_text(encoding="utf-8"))
    found = problems(catalog)
    if found:
        sys.exit("\n".join(found))
    if arguments.check:
        print(f"{len(catalog['aliases'])} aliases, no problems")
        return
    sys.stdout.write("".join(row(catalog, entry) for entry in catalog["aliases"]))


if __name__ == "__main__":
    main()
