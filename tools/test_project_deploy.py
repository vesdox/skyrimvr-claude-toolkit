import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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

    def test_pinned_node_runtime_provenance(self):
        provenance_path = (
            deploy.ROOT / "bridges" / "windows" / "project-deploy" /
            "node-runtime-v24.15.0.json"
        )
        provenance = json.loads(provenance_path.read_text())
        self.assertEqual(provenance["version"], "24.15.0")
        self.assertEqual(provenance["node_exe_size"], 91694408)
        self.assertEqual(
            provenance["node_exe_sha256"],
            "3331e1ffe19874215472217c5e94f5a0c6d8e18c4ac7111d3937aa0ad5e9b4a5",
        )
        self.assertTrue(provenance["verification"]["signed_archive_sha256_matches_download"])
        self.assertTrue(provenance["verification"]["extracted_node_sha256_matches_owner_observation"])

    def test_provisioning_avoids_administrator_side_user_evaluation(self):
        provision = (
            deploy.ROOT / "bridges" / "windows" / "project-deploy" / "provision.ps1"
        ).read_text()
        self.assertNotIn("sshd -T", provision)
        self.assertNotIn("'-T'", provision)
        self.assertIn("& $Sshd '-t' '-f' $SshConfig", provision)
        self.assertIn("& $Sshd '-t' '-f' $Candidate", provision)
        self.assertIn("candidate does not contain exactly the canonical managed SkyrimDeploy block", provision)
        self.assertIn("$SavedErrorActionPreference = $ErrorActionPreference", provision)
        self.assertIn("$ErrorActionPreference = 'Continue'", provision)
        self.assertIn("$SshVersionExit = $LASTEXITCODE", provision)
        self.assertIn("$ErrorActionPreference = $SavedErrorActionPreference", provision)
        self.assertNotIn(r"D:\Program Files\nodejs\node.exe", provision)
        self.assertIn("Assert-Hash $NodeRuntime $ExpectedNodeHash", provision)
        self.assertIn("Set-ProtectedRuntimeDirectoryAcl $RuntimeDirectory", provision)
        self.assertLess(
            provision.index("Assert-Hash $NodeRuntime $ExpectedNodeHash"),
            provision.index("$NodeVersion = (& $NodeDestination '--version'"),
        )

    def test_dry_run_never_starts_ssh(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "mods"
            destination = evidence / "Hoarfrost - Development" / "SKSE" / "Plugins"
            destination.mkdir(parents=True)
            existing = destination / "Hoarfrost.dll"
            existing.write_bytes(b"old")
            source = root / "Hoarfrost.dll"
            source.write_bytes(b"new")
            environment = {
                "deployment": {
                    "mo2_mods_root_windows": r"D:\Games\ASSOS\mods",
                    "mo2_mods_root_evidence": str(evidence),
                }
            }
            target = {"mod": "Hoarfrost - Development"}
            artifacts = [{
                "id": "dll",
                "provenance": "windows-native-build",
                "source": source,
                "destination": "SKSE/Plugins/Hoarfrost.dll",
                "sha256": deploy.sha256_file(source),
            }]
            with mock.patch.object(deploy.subprocess, "Popen") as popen:
                deploy.dry_run(environment, target, artifacts)
            popen.assert_not_called()

    def test_ssh_bridge_requires_exact_identity_and_forced_command(self):
        with tempfile.TemporaryDirectory() as directory:
            identity = Path(directory) / "deploy-key"
            identity.write_text("private-test-key")
            identity.chmod(0o600)
            known_hosts = Path(directory) / "known-hosts"
            known_hosts.write_text(
                "100.113.242.33 ssh-ed25519 "
                "AAAAC3NzaC1lZDI1NTE5AAAAILUEe4QLCur7cCGeKR8ujR7Mx2QH0/lRBUW3OuzS7GBM\n"
            )
            known_hosts.chmod(0o600)
            environment = {"bridges": {"project_deploy": {
                "protocol": "project-deploy-ssh-v1",
                "host": "100.113.242.33",
                "port": 22,
                "user": "SkyrimDeploy",
                "identity_file": str(identity),
                "known_hosts_file": str(known_hosts),
                "host_key_sha256": "SHA256:Hx/P6Q5YyPQmche/iwfecrqMccp03G1dAJFmSO/xwpE",
                "command": "project-deploy-v1",
            }}}
            resolved = deploy.ssh_bridge_config(environment)
            self.assertEqual(resolved["user"], "SkyrimDeploy")
            self.assertEqual(resolved["port"], 22)
            environment["bridges"]["project_deploy"]["port"] = 2222
            with self.assertRaises(deploy.DeployError):
                deploy.ssh_bridge_config(environment)
            environment["bridges"]["project_deploy"]["port"] = 22
            environment["bridges"]["project_deploy"]["user"] = "HoarfrostBuild"
            with self.assertRaises(deploy.DeployError):
                deploy.ssh_bridge_config(environment)
            environment["bridges"]["project_deploy"]["user"] = "SkyrimDeploy"
            environment["bridges"]["project_deploy"]["command"] = "powershell.exe"
            with self.assertRaises(deploy.DeployError):
                deploy.ssh_bridge_config(environment)


if __name__ == "__main__":
    unittest.main()
