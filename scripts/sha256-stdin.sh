#!/bin/bash

set -euo pipefail

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
else
    echo "ERROR: sha256sum or shasum is required" >&2
    exit 1
fi
