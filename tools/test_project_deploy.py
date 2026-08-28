import json
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import project_deploy as deploy
import smoke_project_deploy_ssh as smoke


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
        self.assertIn("Set-ProtectedDirectoryAcl $ProtectedRoot", provision)
        self.assertIn("Set-ProtectedDirectoryAcl $RuntimeDirectory", provision)
        self.assertIn("Assert-NoBroadMutationAcl", provision)
        self.assertIn("Assert-NoBroadAncestorReplacementAcl", provision)
        self.assertIn("Assert-ProtectedPathIntegrity $SshConfig $SshDirectory", provision)
        self.assertIn("Assert-ProtectedPathIntegrity $PowerShell 'C:\\Windows'", provision)
        self.assertIn("C:/Program Files/SkyrimDeployBridge/openssh/authorized_keys", provision)
        self.assertIn("-EncodedCommand $ForceCommandEncoded", provision)
        self.assertNotIn("PermitUserEnvironment no", provision)
        self.assertIn("active global PermitUserEnvironment yes is incompatible", provision)
        self.assertIn("global sshd Include prevents static PermitUserEnvironment policy inspection", provision)
        managed = re.search(r"\$ManagedLines = @\((.*?)\n\)", provision, re.DOTALL)
        self.assertIsNotNone(managed)
        match_directives = set(re.findall(r"['\"]    ([A-Za-z0-9]+)", managed.group(1)))
        # OpenSSH_for_Windows_9.5p2 servconf.c marks each of these SSHCFG_ALL.
        self.assertEqual(match_directives, {
            "AuthenticationMethods", "PubkeyAuthentication", "PasswordAuthentication",
            "KbdInteractiveAuthentication", "PermitEmptyPasswords", "AuthorizedKeysFile",
            "ForceCommand", "DisableForwarding", "AllowTcpForwarding",
            "AllowStreamLocalForwarding", "AllowAgentForwarding", "X11Forwarding",
            "GatewayPorts", "PermitTunnel", "PermitOpen", "PermitListen", "PermitTTY",
            "PermitUserRC", "MaxAuthTries", "MaxSessions", "ChannelTimeout",
        })
        self.assertNotIn("C:/ProgramData/SkyrimToolBridge/project-deploy/invoke-ssh.ps1", provision)
        self.assertIn("$ManagedDirectories = @($ProtectedRoot,$BridgeDirectory,$RuntimeDirectory,$KeyDirectory)", provision)
        self.assertIn("for ($Index = $DirectoryState.Count - 1; $Index -ge 0; $Index--)", provision)
        wrapper = (
            deploy.ROOT / "bridges" / "windows" / "project-deploy" / "invoke-ssh.ps1"
        ).read_text()
        self.assertIn(r"C:\Program Files\SkyrimDeployBridge\runtime\node.exe", wrapper)
        self.assertNotIn(r"C:\ProgramData\SkyrimToolBridge\project-deploy\runtime", wrapper)
        bridge = (
            deploy.ROOT / "bridges" / "windows" / "project-deploy" / "bridge.js"
        ).read_text()
        self.assertIn("rollback failed to remove new destination", bridge)
        self.assertIn("remove rollback backup directory", bridge)
        self.assertIn(".release-${crypto.randomUUID()}", bridge)
        self.assertNotIn(r"C:\\ProgramData\\SkyrimToolBridge\\project-deploy\\config.json", bridge)
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

    def test_known_hosts_parser_ignores_comments_and_blank_lines_only(self):
        with tempfile.TemporaryDirectory() as directory:
            known_hosts = Path(directory) / "known-hosts"
            known_hosts.write_text(
                "# 100.113.242.33:22 SSH-2.0-OpenSSH_for_Windows_9.5\n\n"
                "100.113.242.33 ssh-ed25519 AAAAtest\n"
            )
            self.assertEqual(
                deploy.known_hosts_key_entries(known_hosts),
                [["100.113.242.33", "ssh-ed25519", "AAAAtest"]],
            )
            known_hosts.write_text("# comment only\n")
            self.assertEqual(deploy.known_hosts_key_entries(known_hosts), [])

    def test_smoke_corrections_cover_runtime_audit_and_apply_serialization(self):
        bridge = (
            deploy.ROOT / "bridges" / "windows" / "project-deploy" / "bridge.js"
        ).read_text()
        smoke = (
            deploy.ROOT / "tools" / "smoke_project_deploy_ssh.py"
        ).read_text()
        self.assertIn("node_runtime_write_open_refused", bridge)
        self.assertIn("await acquireApplyLock(lockPath)", bridge)
        self.assertIn("result.audit = audit(", bridge)
        self.assertIn("durable audit record could not be read back exactly once", bridge)
        self.assertIn('require_audit_proof(health, "health")', smoke)
        self.assertIn('require_audit_proof(smoke, "smoke")', smoke)

    def test_audit_identity_uses_pinned_sid_and_case_insensitive_account_name(self):
        response = {
            "request_id": "520ea820-7caa-4069-acad-801940fcf28d",
            "audit": {
                "verified": True,
                "request_id": "520ea820-7caa-4069-acad-801940fcf28d",
                "operation": "health",
                "event": "health",
                "identity": "WORKGROUP\\skyrimdeploy",
                "sid": smoke.EXPECTED_SID,
                "ssh_connection": "100.97.12.82 41632 100.113.242.33 22",
                "ok": True,
                "record_sha256": "a" * 64,
            },
        }
        smoke.require_audit_proof(response, "health")
        response["audit"]["identity"] = "ELLFONE\\SkyrimDeploy"
        smoke.require_audit_proof(response, "health")
        response["audit"]["identity"] = "WORKGROUP\\OtherAccount"
        with self.assertRaises(deploy.DeployError):
            smoke.require_audit_proof(response, "health")
        response["audit"]["identity"] = "WORKGROUP\\skyrimdeploy"
        response["audit"]["sid"] = "S-1-5-21-incorrect"
        with self.assertRaises(deploy.DeployError):
            smoke.require_audit_proof(response, "health")

    def test_bounded_worker_update_pins_exact_historical_pairs(self):
        root = deploy.ROOT / "bridges" / "windows" / "project-deploy"
        worker_hash = deploy.sha256_file(root / "bridge.js")
        current_wrapper_hash = deploy.sha256_file(root / "invoke-ssh.ps1")
        provision = (root / "provision.ps1").read_text()
        updater = (root / "update-worker.ps1").read_text()
        self.assertEqual(worker_hash, "63f7e7ee30ef0c07fc7cd495d68ad5ea185d4a0b42a80141140368ca2f8e77ae")
        self.assertEqual(current_wrapper_hash, "b0d4b3f6b16e7e1a82006b685f0053736e7b77f569b31d8891b9ef602ed329d4")
        self.assertIn(worker_hash, provision)
        self.assertIn(worker_hash, updater)
        self.assertIn(current_wrapper_hash, provision)
        self.assertIn("da34282e5ce0eaff5f0c51973bc80145a1700ed2c2e8bd5a0d5ee8d7f209f907", updater)
        self.assertIn("54c66da67ca4d2e1276a3f420ac3f6226e6a4572cca1e56553fe9168bc07d1a8", updater)
        self.assertIn("8f2485244d2bf3270bb01fe56e9490c1be6d7cdd2e8e1fb2a8931618f08cf30b", updater)
        self.assertIn("sshd_config_changed = $false", updater)
        self.assertIn("[IO.FileMode]::CreateNew", updater)
        self.assertIn("[IO.FileShare]::None", updater)
        self.assertIn("$RollbackErrors.Add(\"worker rollback:", updater)
        self.assertIn("$RollbackErrors.Add(\"wrapper rollback:", updater)

    def test_bounded_allowlist_update_pins_exact_config_wrapper_pairs(self):
        root = deploy.ROOT / "bridges" / "windows" / "project-deploy"
        wrapper_hash = deploy.sha256_file(root / "invoke-ssh.ps1")
        wrapper = (root / "invoke-ssh.ps1").read_text()
        provision = (root / "provision.ps1").read_text()
        updater = (root / "update-allowlist.ps1").read_text()
        old_config = "8103009b73fb481c5a3ae631282bea412ae0aa4b7b95a57ed82a2863c2afac4a"
        new_config = "c1f14081c70aa8d7292f0a68b141d32fa6bb7b09c589a073ac406f49dedd1a61"
        old_wrapper = "da34282e5ce0eaff5f0c51973bc80145a1700ed2c2e8bd5a0d5ee8d7f209f907"
        self.assertEqual(wrapper_hash, "b0d4b3f6b16e7e1a82006b685f0053736e7b77f569b31d8891b9ef602ed329d4")
        self.assertIn(new_config, wrapper)
        self.assertIn(new_config, provision)
        self.assertIn(wrapper_hash, provision)
        for expected in (old_config, new_config, old_wrapper, wrapper_hash):
            self.assertIn(expected, updater)
        self.assertIn("[IO.FileMode]::CreateNew", updater)
        self.assertIn("[IO.FileShare]::None", updater)
        self.assertIn("write-time CAS refused", updater)
        self.assertIn("rollback CAS refused unknown current state", updater)
        self.assertIn("$Stream.Flush($true)", updater)
        self.assertIn("transaction-start.json", updater)
        self.assertIn("config ACL changed during bounded in-place update", updater)
        self.assertIn("wrapper ACL changed during bounded in-place update", updater)
        self.assertIn("$RollbackErrors.Add(\"config rollback:", updater)
        self.assertIn("$RollbackErrors.Add(\"wrapper rollback:", updater)
        self.assertIn("sshd_config_changed = $false", updater)
        self.assertIn("deployment_targets_changed = $false", updater)

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
