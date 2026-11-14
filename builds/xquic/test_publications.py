#!/usr/bin/env python3
"""Check maintainer-owned XQUIC publications and rejected mismatches."""

import contextlib
import importlib.util
import io
from pathlib import Path
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="xquic-publications-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("implementations.json", ".github/workflows/build-images.yml",
                     ".github/workflows/rebuild-all-images.yml"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        spec = importlib.util.spec_from_file_location(
            "publications", ROOT / "validate-image-publications.py")
        self.validator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.validator)
        self.validator.REGISTRY = self.root / "implementations.json"
        self.validator.BUILD_WORKFLOW = (
            self.root / ".github/workflows/build-images.yml")
        self.validator.REBUILD_WORKFLOW = (
            self.root / ".github/workflows/rebuild-all-images.yml")

    def result(self):
        with contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            return self.validator.main()

    def test_both_maintainer_images_match_consumers(self):
        self.assertEqual(self.result(), 0)
        publications, _ = self.validator.build_publications()
        self.assertEqual(set(publications["xquic"]), {
            f"{image}:latest"
            for image in self.validator.XQUIC_MAINTAINER_IMAGES})

    def test_unrecognized_xquic_publisher_is_rejected(self):
        path = self.validator.BUILD_WORKFLOW
        path.write_text(path.read_text().replace(
            "ghcr.io/yanmei-liu/", "ghcr.io/unrecognized/"))
        self.assertEqual(self.result(), 1)

    def test_publication_and_registration_mismatch_is_rejected(self):
        path = self.validator.REGISTRY
        path.write_text(path.read_text().replace(
            "ghcr.io/yanmei-liu/moq-interop-runner-xquic-client:latest",
            "ghcr.io/englishm/moq-interop-runner-xquic-client:latest"))
        self.assertEqual(self.result(), 1)

    def test_other_jobs_cannot_publish_xquic_images(self):
        path = self.validator.BUILD_WORKFLOW
        path.write_text(path.read_text().replace(
            "ghcr.io/englishm/moq-interop-runner-moq-dev-js-client",
            "ghcr.io/yanmei-liu/moq-interop-runner-xquic-client"))
        self.assertEqual(self.result(), 1)


if __name__ == "__main__":
    unittest.main()
