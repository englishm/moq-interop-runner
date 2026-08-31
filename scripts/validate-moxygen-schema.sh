#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=${1:-"$ROOT_DIR/docs/moxygen-relay-support-profile.json"}
SCHEMA=${2:-"$ROOT_DIR/docs/moxygen-relay-support-profile.schema.json"}
RESULT=${3:-}
EXPECTED_SCHEMA_SHA256="5c45f55c6cfd8c6a29f2980d2bf3a29d4abcdb13c22d42f717f4b3d3f0969483"

for file in "$PROFILE" "$SCHEMA"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: missing file: $file" >&2
    exit 1
  fi
done
if [[ -n "$RESULT" && ! -f "$RESULT" ]]; then
  echo "ERROR: missing file: $RESULT" >&2
  exit 1
fi

schema_sha256() {
  local hash

  if command -v sha256sum >/dev/null 2>&1; then
    read -r hash _ < <(sha256sum "$1")
  elif command -v shasum >/dev/null 2>&1; then
    read -r hash _ < <(shasum -a 256 "$1")
  else
    echo "ERROR: sha256sum or shasum is required" >&2
    exit 1
  fi
  printf '%s' "$hash"
}

actual_schema_sha256=$(schema_sha256 "$SCHEMA")
if [[ "$actual_schema_sha256" != "$EXPECTED_SCHEMA_SHA256" ]]; then
  echo "ERROR: schema digest mismatch: expected $EXPECTED_SCHEMA_SHA256, got $actual_schema_sha256" >&2
  exit 1
fi

if command -v bun >/dev/null 2>&1 && bun -e 'import Ajv from "ajv"; if (typeof Ajv !== "function") process.exit(1)' >/dev/null 2>&1; then
  PROFILE_PATH="$PROFILE" SCHEMA_PATH="$SCHEMA" RESULT_PATH="$RESULT" bun -e '
    import Ajv from "ajv";
    import { readFileSync } from "node:fs";

    const schema = JSON.parse(readFileSync(process.env.SCHEMA_PATH, "utf8"));
    const profile = JSON.parse(readFileSync(process.env.PROFILE_PATH, "utf8"));
    const createAjv = () => {
      const ajv = new Ajv({ allErrors: true, strict: false });
      ajv.addFormat("uri", {
        type: "string",
        validate: (value) => {
          try { new URL(value); return true; } catch { return false; }
        },
      });
      ajv.addFormat("date-time", {
        type: "string",
        validate: (value) => {
          if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) return false;
          const date = new Date(value);
          return !Number.isNaN(date.valueOf()) && date.toISOString().replace(".000Z", "Z") === value;
        },
      });
      return ajv;
    };
    const validate = createAjv().compile(schema);
    if (!validate(profile)) {
      console.error(JSON.stringify(validate.errors, null, 2));
      process.exit(1);
    }
    if (process.env.RESULT_PATH) {
      const result = JSON.parse(readFileSync(process.env.RESULT_PATH, "utf8"));
      const resultSchema = { $schema: schema.$schema, definitions: schema.definitions, $ref: "#/definitions/result_record" };
      const validateResult = createAjv().compile(resultSchema);
      if (!validateResult(result)) {
        console.error(JSON.stringify(validateResult.errors, null, 2));
        process.exit(1);
      }
    }
  '
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
  PROFILE_PATH="$PROFILE" SCHEMA_PATH="$SCHEMA" RESULT_PATH="$RESULT" python3 -c '
import json
import os
import jsonschema

with open(os.environ["SCHEMA_PATH"], encoding="utf-8") as schema_file:
    schema = json.load(schema_file)
with open(os.environ["PROFILE_PATH"], encoding="utf-8") as profile_file:
    profile = json.load(profile_file)
jsonschema.Draft7Validator.check_schema(schema)
jsonschema.Draft7Validator(schema, format_checker=jsonschema.FormatChecker()).validate(profile)
if os.environ["RESULT_PATH"]:
    with open(os.environ["RESULT_PATH"], encoding="utf-8") as result_file:
        result = json.load(result_file)
    result_schema = {"$schema": schema["$schema"], "definitions": schema["definitions"], "$ref": "#/definitions/result_record"}
    jsonschema.Draft7Validator.check_schema(result_schema)
    jsonschema.Draft7Validator(result_schema, format_checker=jsonschema.FormatChecker()).validate(result)
'
else
  echo "ERROR: schema validation requires existing Bun/Ajv or Python/jsonschema" >&2
  exit 1
fi

echo "Validated moxygen relay support profile${RESULT:+ and result} against Draft-07 schema"
