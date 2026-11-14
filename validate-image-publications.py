#!/usr/bin/env python3
"""Validate runner-owned GHCR publications against registry consumers."""

import json
import re
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parent
BUILD_WORKFLOW = ROOT / ".github/workflows/build-images.yml"
REBUILD_WORKFLOW = ROOT / ".github/workflows/rebuild-all-images.yml"
REGISTRY = ROOT / "implementations.json"
RUNNER_IMAGE_PREFIX = "ghcr.io/englishm/moq-interop-runner-"


def registry_images() -> set[str]:
    registry = json.loads(REGISTRY.read_text())
    images = set()
    for implementation in registry["implementations"].values():
        for role in implementation["roles"].values():
            image = role.get("docker", {}).get("image", "")
            if image.startswith(RUNNER_IMAGE_PREFIX):
                images.add(image)
    return images


def build_publications() -> tuple[dict[str, list[str]], list[str]]:
    lines = BUILD_WORKFLOW.read_text().splitlines()
    jobs: dict[str, list[str]] = {}
    assigned_jobs = set()
    parsed_assignments = 0
    current_jobs: list[str] = []
    in_config_case = False

    for line in lines:
        if line.strip() == 'case "$IMPL" in':
            in_config_case = True
            continue
        if in_config_case and line.strip() == "esac":
            break
        if not in_config_case:
            continue

        case_match = re.match(r"^\s+([a-z0-9][a-z0-9|.-]*)\)$", line)
        if case_match:
            current_jobs = case_match.group(1).split("|")
            for job in current_jobs:
                if job in jobs:
                    raise ValueError(f"duplicate build case: {job}")
                jobs[job] = []
            continue

        if line.strip() in {";;", "*)"}:
            current_jobs = []
            continue

        if "echo 'images=" not in line:
            continue
        assignment = re.match(r'^\s*echo \'images=(.+)\' >> "\$GITHUB_OUTPUT"$', line)
        if not assignment or not current_jobs:
            raise ValueError("invalid images output assignment")
        if any(job in assigned_jobs for job in current_jobs):
            raise ValueError(f"duplicate images output assignment: {'|'.join(current_jobs)}")
        try:
            entries = json.loads(assignment.group(1))
        except json.JSONDecodeError as error:
            raise ValueError(f"invalid images output JSON: {error.msg}") from error
        if not isinstance(entries, list) or not entries:
            raise ValueError(f"empty images output assignment: {'|'.join(current_jobs)}")
        for entry in entries:
            image = entry.get("ghcr", "") if isinstance(entry, dict) else ""
            if not re.fullmatch(re.escape(RUNNER_IMAGE_PREFIX) + r"[a-z0-9][a-z0-9._-]*", image):
                raise ValueError(f"invalid runner-owned GHCR publication: {image or entry!r}")
            for job in current_jobs:
                jobs[job].append(f"{image}:latest")
        assigned_jobs.update(current_jobs)
        parsed_assignments += 1

    options = []
    if sum("echo 'images=" in line for line in lines) != parsed_assignments:
        raise ValueError("images output assignment outside a configured build case")

    dispatch_start = lines.index("  workflow_dispatch:") + 1
    dispatch_block = []
    for line in lines[dispatch_start:]:
        indentation = len(line) - len(line.lstrip())
        if line.strip() and not line.lstrip().startswith("#") and indentation <= 2:
            break
        dispatch_block.append(line)
    if dispatch_block.count("      implementation:") != 1:
        raise ValueError("workflow_dispatch must define exactly one implementation input")
    input_start = dispatch_block.index("      implementation:") + 1
    input_block = []
    for line in dispatch_block[input_start:]:
        indentation = len(line) - len(line.lstrip())
        if line.strip() and not line.lstrip().startswith("#") and indentation <= 6:
            break
        input_block.append(line)
    if input_block.count("        options:") != 1:
        raise ValueError("implementation input must define exactly one options list")
    options_start = input_block.index("        options:") + 1
    option_lines = []
    for line in input_block[options_start:]:
        indentation = len(line) - len(line.lstrip())
        if line.strip() and not line.lstrip().startswith("#") and indentation <= 8:
            break
        if line.strip() and not line.lstrip().startswith("#"):
            option_lines.append(line)
    for line in option_lines:
        option = re.match(r"^\s{10}- ([a-z0-9.-]+)$", line)
        if not option:
            raise ValueError("implementation options must contain plain build job names")
        options.append(option.group(1))

    return jobs, options


def rebuild_job_block() -> list[str]:
    lines = REBUILD_WORKFLOW.read_text().splitlines()
    try:
        start = lines.index("  build:") + 1
    except ValueError as error:
        raise ValueError("Rebuild All is missing jobs.build") from error

    block = []
    for line in lines[start:]:
        indentation = len(line) - len(line.lstrip())
        if line.strip() and not line.lstrip().startswith("#") and indentation <= 2:
            break
        block.append(line)
    return block


def rebuild_jobs(block: list[str]) -> list[str]:
    try:
        start = block.index("      matrix:") + 1
    except ValueError as error:
        raise ValueError("Rebuild All jobs.build is missing strategy.matrix") from error

    matrix = []
    for line in block[start:]:
        indentation = len(line) - len(line.lstrip())
        if line.strip() and not line.lstrip().startswith("#") and indentation <= 6:
            break
        matrix.append(line)
    matrix_keys = [
        line.strip()
        for line in matrix
        if line.strip() and not line.lstrip().startswith("#") and len(line) - len(line.lstrip()) == 8
    ]
    if matrix_keys != ["include:"]:
        raise ValueError("Rebuild All strategy.matrix must contain only include")
    include_start = matrix.index("        include:") + 1
    include = []
    for line in matrix[include_start:]:
        indentation = len(line) - len(line.lstrip())
        if line.strip() and not line.lstrip().startswith("#") and indentation <= 8:
            break
        include.append(line)
    rows = [line for line in include if line.strip() and not line.lstrip().startswith("#")]
    if len(rows) % 2:
        raise ValueError("Rebuild All matrix.include contains an incomplete row")
    jobs = []
    for index in range(0, len(rows), 2):
        implementation = re.match(r"^\s{10}- implementation: ([a-z0-9.-]+)$", rows[index])
        if not implementation or rows[index + 1] != "            ref: ''":
            raise ValueError("Rebuild All matrix.include rows must contain implementation then ref")
        jobs.append(implementation.group(1))
    return jobs


def report_duplicates(label: str, values: list[str]) -> bool:
    duplicates = sorted(value for value, count in Counter(values).items() if count > 1)
    if not duplicates:
        return False
    print(f"ERROR: duplicate {label}", file=sys.stderr)
    for value in duplicates:
        print(f"  duplicate: {value}", file=sys.stderr)
    return True


def validate_rebuild_wiring(block: list[str]) -> bool:
    failed = False
    if block.count("    uses: ./.github/workflows/build-images.yml") != 1:
        failed = True
        print("ERROR: Rebuild All must contain exactly one reusable workflow mapping", file=sys.stderr)

    if block.count("    with:") != 1:
        print("ERROR: Rebuild All must contain exactly one jobs.build.with mapping", file=sys.stderr)
        return True
    start = block.index("    with:") + 1
    with_block = []
    for line in block[start:]:
        indentation = len(line) - len(line.lstrip())
        if line.strip() and not line.lstrip().startswith("#") and indentation <= 4:
            break
        with_block.append(line)

    required_inputs = {
        "implementation matrix input": "      implementation: ${{ matrix.implementation }}",
        "ref matrix input": "      ref: ${{ matrix.ref }}",
    }
    for label, line in required_inputs.items():
        if with_block.count(line) != 1:
            failed = True
            print(f"ERROR: Rebuild All must contain exactly one {label} mapping", file=sys.stderr)
    return failed


def report_difference(label: str, expected: set[str], actual: set[str]) -> bool:
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if not missing and not extra:
        return False
    print(f"ERROR: {label}", file=sys.stderr)
    for item in missing:
        print(f"  missing: {item}", file=sys.stderr)
    for item in extra:
        print(f"  unexpected: {item}", file=sys.stderr)
    return True


def main() -> int:
    consumers = registry_images()
    try:
        publications_by_job, dispatch_jobs = build_publications()
        rebuild_block = rebuild_job_block()
        rebuild_entries = rebuild_jobs(rebuild_block)
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    configured_jobs = set(publications_by_job)
    publications = [image for images in publications_by_job.values() for image in images]
    published_images = set(publications)
    failed = False

    failed |= report_duplicates("image publications", publications)
    failed |= report_duplicates("workflow_dispatch options", dispatch_jobs)
    failed |= report_duplicates("Rebuild All entries", rebuild_entries)
    failed |= validate_rebuild_wiring(rebuild_block)

    empty_jobs = sorted(job for job, images in publications_by_job.items() if not images)
    if empty_jobs:
        failed = True
        print("ERROR: build jobs without runner-owned GHCR publications", file=sys.stderr)
        for job in empty_jobs:
            print(f"  empty: {job}", file=sys.stderr)

    failed |= report_difference(
        "build workflow publications do not match registry consumers",
        consumers,
        published_images,
    )
    failed |= report_difference(
        "workflow_dispatch options do not match configured build jobs",
        configured_jobs,
        set(dispatch_jobs),
    )
    failed |= report_difference(
        "Rebuild All entries do not match configured build jobs",
        configured_jobs,
        set(rebuild_entries),
    )

    if failed:
        return 1

    print(
        f"Validated {len(published_images)} runner-owned GHCR images "
        f"across {len(configured_jobs)} build jobs."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
