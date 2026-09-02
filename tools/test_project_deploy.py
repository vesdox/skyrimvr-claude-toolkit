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

    def test_hoarfrost_schema_v4_proof_target_is_exactly_confined(self):
        project = deploy.load_toml(deploy.PROJECTS_DIR / "hoarfrost.toml")
        environment = deploy.load_toml(deploy.ENVIRONMENTS_DIR / "assos.toml")
        proof = deploy.target_config(project, "assos", "schema-v4-runtime-proof")
        self.assertEqual(proof["mod"], "Hoarfrost - Schema V4 Runtime Proof")
        deploy.validate_target_sets(
            proof,
            "schema-v4-runtime-proof",
            ["schema-v4-runtime-proof-native", "schema-v4-runtime-proof-inputs-inject"],
        )
        self.assertEqual(
            deploy.windows_destination(
                environment, proof, "SKSE/Plugins/Hoarfrost.dll"
            ),
            r"D:\Games\Wabbajack\Modlists\ASSOS\mods\Hoarfrost - Schema V4 Runtime Proof\SKSE\Plugins\Hoarfrost.dll",
        )

        development = deploy.target_config(project, "assos", "development")
        with self.assertRaises(deploy.DeployError):
            deploy.validate_target_sets(
                development,
                "development",
                ["schema-v4-runtime-proof-native"],
            )
        for unregistered in (
            "arbitrary-sibling-mod",
            "profiles/ASSOS/saves",
            r"C:\\generic\\path",
        ):
            with self.subTest(unregistered=unregistered):
                with self.assertRaises(deploy.DeployError):
                    deploy.target_config(project, "assos", unregistered)

    def test_stage_2a_inject_set_is_exactly_two_registered_runtime_test_files(self):
        project = deploy.load_toml(deploy.PROJECTS_DIR / "hoarfrost.toml")
        target = deploy.target_config(project, "assos", "schema-v4-runtime-proof")
        selected = ["schema-v4-runtime-proof-inputs-inject"]
        deploy.validate_target_sets(target, "schema-v4-runtime-proof", selected)
        artifacts = deploy.resolve_artifacts(project, selected, None)
        self.assertEqual(
            [(item["id"], item["destination"], item["sha256"]) for item in artifacts],
            [
                (
                    "schema-v4-runtime-proof-mode-inject",
                    "SKSE/Plugins/Hoarfrost/RuntimeTests/runtime-proof-mode.txt",
                    "aa22a3b5727e1ea2d12abc582bad1731ba07ec93a651fc82137fe891c4002aae",
                ),
                (
                    "schema-v4-runtime-proof-fixture-inject",
                    "SKSE/Plugins/Hoarfrost/RuntimeTests/schema-v4-persistence-proof.json",
                    "f0d97705de0969731b2227b0d59c8120364e8b5c521f0125a3dd6a5c3f897e4c",
                ),
            ],
        )
        self.assertEqual(
            {str(Path(item["destination"]).parent) for item in artifacts},
            {"SKSE/Plugins/Hoarfrost/RuntimeTests"},
        )

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

    def test_worker_parent_creation_is_registry_derived_and_transactional(self):
        bridge = (
            deploy.ROOT / "bridges" / "windows" / "project-deploy" / "bridge.js"
        ).read_text()
        self.assertIn("for (const layout of layouts)", bridge)
        self.assertIn("for (const directory of layout.missing)", bridge)
        self.assertNotIn("input.directories", bridge)
        self.assertNotIn("recursive: true });\n    const identity = await directoryIdentity", bridge)
        self.assertIn("await removeCreatedDirectories(currentTarget.root, createdDirectories)", bridge)
        self.assertIn("await fs.promises.rmdir(entry.path)", bridge)
        self.assertIn("created_directories", bridge)
        self.assertIn("rolled_back_directories", bridge)
        self.assertIn("required_missing_parents", bridge)
        self.assertIn("pre_existing_parents", bridge)

    def test_bounded_worker_update_pins_exact_current_and_candidate_pairs(self):
        root = deploy.ROOT / "bridges" / "windows" / "project-deploy"
        worker_hash = deploy.sha256_file(root / "bridge.js")
        wrapper_hash = deploy.sha256_file(root / "invoke-ssh.ps1")
        updater = (root / "update-worker.ps1").read_text()
        old_worker = "63f7e7ee30ef0c07fc7cd495d68ad5ea185d4a0b42a80141140368ca2f8e77ae"
        old_wrapper = "909b7dc6ab86b2f719cbb9cd626e4089b56ee5f79d36e400a948418a892cb3ab"
        config_hash = "4ecdc351f552c5128deb5f5c9e2190f8d6fe7375126e2a1d6c03452f52b63617"
        self.assertEqual(worker_hash, "11e00d9f224e94a4d290178a97a68862c20f7a15e6c25b7c0363f1b1a0e2e6a3")
        self.assertEqual(wrapper_hash, "09657a4fe4ba0e63f8ba6453bd1828a73bd73e612b9f5dc2fe430e890893db80")
        for expected in (old_worker, old_wrapper, worker_hash, wrapper_hash, config_hash):
            self.assertIn(expected, updater)
        self.assertIn("write-time CAS refused", updater)
        self.assertIn("rollback CAS refused unknown current state", updater)
        self.assertIn("transaction-start.json", updater)
        self.assertIn("failure.json", updater)
        self.assertIn("sshd_config_changed = $false", updater)
        self.assertIn("deployment_targets_changed = $false", updater)
        self.assertIn("mod_content_touched = $false", updater)
        self.assertIn("[IO.FileMode]::CreateNew", updater)
        self.assertIn("[IO.FileShare]::None", updater)
        self.assertIn("$RollbackErrors.Add(\"worker rollback:", updater)
        self.assertIn("$RollbackErrors.Add(\"wrapper rollback:", updater)

    def test_bounded_allowlist_update_pins_exact_config_wrapper_pairs(self):
        root = deploy.ROOT / "bridges" / "windows" / "project-deploy"
        config_hash = deploy.sha256_file(root / "config.json")
        wrapper = (root / "invoke-ssh.ps1").read_text()
        provision = (root / "provision.ps1").read_text()
        updater = (root / "update-allowlist.ps1").read_text()
        old_config = "3761b240a774a97b732548d535b715b8cf887f17079e1a71398372b2acdb579c"
        old_wrapper = "c8b6c56d2ad0bd864e61fb49bf96f17140de600ababd47707d669a513e117023"
        self.assertEqual(config_hash, "4ecdc351f552c5128deb5f5c9e2190f8d6fe7375126e2a1d6c03452f52b63617")
        self.assertIn(config_hash, wrapper)
        self.assertIn(old_config, provision)
        self.assertIn(old_wrapper, provision)
        historical_allowlist_wrapper = "909b7dc6ab86b2f719cbb9cd626e4089b56ee5f79d36e400a948418a892cb3ab"
        for expected in (old_config, config_hash, old_wrapper, historical_allowlist_wrapper):
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
