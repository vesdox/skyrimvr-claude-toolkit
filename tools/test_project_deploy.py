import tempfile
import unittest
from pathlib import Path

import project_deploy as deploy


class ProjectDeployTests(unittest.TestCase):
    def test_safe_relative_rejects_escape_and_absolute_paths(self):
        for value in ("../evil.dll", "a/../evil.dll", "/tmp/evil", "C:\\evil.dll"):
            with self.subTest(value=value):
                with self.assertRaises(deploy.DeployError):
                    deploy.safe_relative(value, "test")

    def test_hash_manifest_accepts_only_bounded_relative_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "artifacts.sha256"
            manifest.write_text("a" * 64 + "  Hoarfrost.dll\n")
            self.assertEqual(
                deploy.parse_hash_manifest(manifest),
                {"Hoarfrost.dll": "a" * 64},
            )
            manifest.write_text("a" * 64 + "  ../Hoarfrost.dll\n")
            with self.assertRaises(deploy.DeployError):
                deploy.parse_hash_manifest(manifest)

    def test_source_proof_requires_one_named_pinned_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            proof = Path(directory) / "source.sha256"
            proof.write_text("a" * 64 + "  /tmp/build/hoarfrost-src.tar.gz\n")
            self.assertEqual(deploy.parse_source_proof(proof), "a" * 64)
            proof.write_text("not-a-hash  /tmp/build/hoarfrost-src.tar.gz\n")
            with self.assertRaises(deploy.DeployError):
                deploy.parse_source_proof(proof)
            proof.write_text("a" * 64 + "  unrelated.tar.gz\n")
            with self.assertRaises(deploy.DeployError):
                deploy.parse_source_proof(proof)

    def test_target_resolution_refuses_unregistered_and_ambiguous_targets(self):
        project = {
            "id": "sample",
            "deployment": {
                "targets": [
                    {"id": "development", "environment": "assos", "mod": "Sample", "sets": ["native"]}
                ]
            },
        }
        self.assertEqual(
            deploy.target_config(project, "assos", "development")["mod"],
            "Sample",
        )
        with self.assertRaises(deploy.DeployError):
            deploy.target_config(project, "assos", "other")
        project["deployment"]["targets"][0]["mod"] = ".."
        with self.assertRaises(deploy.DeployError):
            deploy.target_config(project, "assos", "development")
        project["deployment"]["targets"][0]["mod"] = "Sample"
        project["deployment"]["targets"].append(
            {"id": "development", "environment": "assos", "mod": "Duplicate", "sets": ["native"]}
        )
        with self.assertRaises(deploy.DeployError):
            deploy.target_config(project, "assos", "development")

    def test_artifact_request_refuses_unregistered_set(self):
        with self.assertRaises(deploy.DeployError):
            deploy.resolve_artifacts(
                {"repo": "/tmp", "deployment": {"sets": []}},
                ["not-registered"],
                None,
            )


if __name__ == "__main__":
    unittest.main()
