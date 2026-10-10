#!/usr/bin/env python3
"""Offline regression tests: synthetic archives only; external commands are mocked."""
import copy
import io
import json
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import archive_evidence as evidence
import release


SUBMISSION_ID = "11111111-2222-4333-8444-555555555555"
OTHER_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
TEAM = "TESTTEAM01"
CERTIFICATE = "0123456789abcdef" * 2 + "01234567"
CODE_HASH = "abcdef0123456789" * 2 + "abcdef01"
UPLOAD_HASH = "0123456789abcdef" * 4


def write_json(path, value):
    path.write_text(json.dumps(value))


def write_plist(path, value):
    path.write_bytes(plistlib.dumps(value))


class OfflineTestCase(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tsx-release-tests-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.temporary_root = self.root / "system-temporary"
        self.patch(evidence, "TEMPORARY_ROOTS", (self.temporary_root,))
        self.command = self.patch(
            release, "run", side_effect=AssertionError("Unexpected external release command"))
        self.recorded_command = self.patch(
            release, "recorded_command", side_effect=AssertionError("Unexpected recorded external command"))
        self.process = self.patch(
            release.subprocess, "run", side_effect=AssertionError("External processes are forbidden in tests"))

    def patch(self, target, attribute, *args, **kwargs):
        patcher = mock.patch.object(target, attribute, *args, **kwargs)
        self.addCleanup(patcher.stop)
        return patcher.start()


class PersistentDirectoryTests(OfflineTestCase):
    def test_accepts_existing_and_new_durable_directories(self):
        existing = self.root / "ReleaseArchives"
        existing.mkdir()
        for path in (existing, existing / "candidate", self.root / "builds" / "candidate"):
            with self.subTest(path=path.name):
                self.assertEqual(evidence.persistent_directory(path), path)

    def test_rejects_git_directories_and_worktree_git_files(self):
        for kind in ("directory", "file", "broken-symlink"):
            with self.subTest(kind=kind):
                repository = self.root / kind
                repository.mkdir()
                marker = repository / ".git"
                if kind == "directory":
                    marker.mkdir()
                    (marker / "HEAD").write_text("ref: refs/heads/main\n")
                elif kind == "file":
                    marker.write_text("gitdir: /synthetic/nonexistent/worktree\n")
                else:
                    marker.symlink_to(self.root / "missing-git-directory")
                for path in (repository, repository / "nested" / "release"):
                    with self.assertRaisesRegex(RuntimeError, "Git working tree"):
                        evidence.persistent_directory(path)

    def test_rejects_build_cache_and_git_path_components(self):
        for component in (".build", "build", "Build", "DerivedData", "cache", "Caches", ".cache", ".git", "TemporaryItems"):
            with self.subTest(component=component):
                with self.assertRaisesRegex(RuntimeError, "build or cache"):
                    evidence.persistent_directory(self.root / component / "release")

    def test_rejects_temporary_root_and_descendants(self):
        for path in (self.temporary_root, self.temporary_root / "release"):
            with self.subTest(path=path.name):
                with self.assertRaisesRegex(RuntimeError, "temporary directory"):
                    evidence.persistent_directory(path)
        sibling = self.root / "system-temporary-archive"
        self.assertEqual(evidence.persistent_directory(sibling), sibling)

    def test_rejects_symlinks_into_forbidden_locations(self):
        repository = self.root / "source-tree"
        (repository / ".git").mkdir(parents=True)
        (repository / ".git/HEAD").write_text("ref: refs/heads/main\n")
        destinations = (self.root / ".build", self.root / "DerivedData", self.root / "cache",
                        self.temporary_root, repository)
        for index, destination in enumerate(destinations):
            with self.subTest(destination=destination.name):
                destination.mkdir(exist_ok=True)
                alias = self.root / f"alias-{index}"
                alias.symlink_to(destination, target_is_directory=True)
                with self.assertRaises(RuntimeError):
                    evidence.persistent_directory(alias / "release")

    def test_rejects_repository_symlink_that_escapes_to_durable_storage(self):
        repository = self.root / "source-tree"
        (repository / ".git").mkdir(parents=True)
        (repository / ".git/HEAD").write_text("ref: refs/heads/main\n")
        durable = self.root / "ReleaseArchives"
        durable.mkdir()
        alias = repository / "external-evidence"
        alias.symlink_to(durable, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "Git working tree"):
            evidence.persistent_directory(alias / "candidate")

    def test_accepts_safe_symlink_between_durable_locations(self):
        target = self.root / "ReleaseArchives"
        target.mkdir()
        alias = self.root / "archive-alias"
        alias.symlink_to(target, target_is_directory=True)
        self.assertEqual(evidence.persistent_directory(alias / "candidate"), target / "candidate")

    def test_accepts_home_tool_metadata_that_is_not_a_git_repository(self):
        (self.root / ".git/gk").mkdir(parents=True)
        destination = self.root / "Library/Application Support/TSX/ReleaseArchives/candidate"
        self.assertEqual(evidence.persistent_directory(destination), destination)

    def test_rejects_partial_git_store_with_any_repository_anchor(self):
        for name in ("HEAD", "config", "objects", "commondir", "refs"):
            with self.subTest(anchor=name):
                root = self.root / name
                (root / ".git").mkdir(parents=True)
                (root / ".git" / name).write_text("Synthetic partial repository")
                with self.assertRaisesRegex(RuntimeError, "Git working tree"):
                    evidence.persistent_directory(root / "ReleaseArchives/candidate")

    def test_rejects_regular_file(self):
        path = self.root / "record.json"
        path.write_text("{}")
        with self.assertRaisesRegex(RuntimeError, "not a directory"):
            evidence.persistent_directory(path)


class ArchiveFixtureTestCase(OfflineTestCase):
    def setUp(self):
        super().setUp()
        self.archives = self.root / "Archives"
        self.patch(evidence, "ARCHIVES", self.archives)
        self.archive = self.archives / "2026-01-02" / "TSX fixture.xcarchive"
        self.product = self.archive / "Products/Applications/TSX.app"
        self.directory = self.root / "ReleaseArchives/candidate"
        self.directory.mkdir(parents=True)
        self.product.joinpath("Contents/MacOS").mkdir(parents=True)
        self.product.joinpath("Contents/Resources").mkdir()
        self.app_properties = {
            "CFBundleIdentifier": "com.lumax.tsx", "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "7", "CFBundleExecutable": "TSX",
        }
        write_plist(self.product / "Contents/Info.plist", self.app_properties)
        executable = self.product / "Contents/MacOS/TSX"
        executable.write_bytes(b"synthetic executable bytes; never run")
        executable.chmod(0o755)
        (self.product / "Contents/Resources/sample.txt").write_text("Synthetic release fixture.\n")
        (self.product / "Contents/ResourceAlias").symlink_to("Resources", target_is_directory=True)
        properties = dict(self.app_properties, ApplicationPath="Applications/TSX.app",
                          Architectures=["arm64", "x86_64"], Team=TEAM)
        event = {"state": "success", "errors": [], "warnings": [], "infoMessages": [],
                 "date": "2026-01-02T03:04:05Z"}
        self.distribution = {
            "task": "distribute", "destination": "upload", "uploadDestination": "Developer ID",
            "identifier": SUBMISSION_ID, "teamID": TEAM, "certificateSHA1": CERTIFICATE,
            "uploadedBuildNumber": "7", "preparationEvent": copy.deepcopy(event),
            "uploadEvent": copy.deepcopy(event), "processingEvent": {"state": "processing", "errors": []},
        }
        self.archive_info = {"ApplicationProperties": properties, "Distributions": [self.distribution]}
        self.save_archive_info()
        self.submission = self.archive / "Submissions" / SUBMISSION_ID
        self.submitted = self.submission / "TSX.app"
        shutil.copytree(self.product, self.submitted, symlinks=True)
        self.exported = self.root / "XcodeExport/TSX.app"
        shutil.copytree(self.submitted, self.exported, symlinks=True)
        self.log = {
            "logFormatVersion": 1, "jobId": SUBMISSION_ID.lower(), "status": "Accepted",
            "statusSummary": "Ready for distribution", "statusCode": 0, "issues": None,
            "archiveFilename": "TSX.zip", "sha256": UPLOAD_HASH,
            "ticketContents": [self.ticket(architecture=architecture) for architecture in ("arm64", "x86_64")],
        }
        self.save_log()
        product_manifest = evidence.manifest(self.product)
        write_json(self.directory / "archived-app-manifest.json", product_manifest)
        self.source = {
            "schema": 2, "workflow": "xcode-organizer", "commit": "a" * 40,
            "repository": str(release.ROOT), "archivePath": str(self.archive), "version": "1.2.3", "build": "7",
            "applicationProperties": copy.deepcopy(properties),
            "archivedAppManifestSHA256": evidence.manifest_digest(product_manifest),
        }
        self.cdhash = mock.Mock(return_value=CODE_HASH)

    def ticket(self, path="TSX.zip/TSX.app", architecture="arm64"):
        return {"path": path, "arch": architecture, "digestAlgorithm": "SHA-256", "cdhash": CODE_HASH}

    def save_archive_info(self):
        write_plist(self.archive / "Info.plist", self.archive_info)

    def save_log(self):
        write_json(self.submission / "notarization-log.json", self.log)

    def validate_distribution(self):
        return evidence.xcode_distribution(self.archive, self.exported, self.source, TEAM, CERTIFICATE, self.cdhash)


class XcodeDistributionTests(ArchiveFixtureTestCase):
    def test_accepts_matching_export_even_while_processing_event_is_stale(self):
        result = self.validate_distribution()
        self.assertEqual(result["submissionID"], SUBMISSION_ID)
        self.assertEqual(result["status"], "Accepted")
        self.assertEqual(result["appManifestSHA256"], evidence.manifest_digest(evidence.manifest(self.exported)))
        self.cdhash.assert_has_calls([mock.call(self.exported, "arm64"), mock.call(self.exported, "x86_64")])
        self.assertEqual(self.cdhash.call_count, 2)

    def test_rejects_unsuccessful_preparation_or_upload(self):
        for name in ("preparationEvent", "uploadEvent"):
            for alteration in ({"state": "processing"}, {"errors": ["Synthetic upload failure"]}):
                with self.subTest(event=name, alteration=alteration):
                    previous = copy.deepcopy(self.distribution[name])
                    self.distribution[name].update(alteration)
                    self.save_archive_info()
                    with self.assertRaisesRegex(RuntimeError, "must both have succeeded"):
                        self.validate_distribution()
                    self.distribution[name] = previous
        self.cdhash.assert_not_called()

    def test_rejects_missing_or_unaccepted_notarization(self):
        for alteration in ({"status": "In Progress"}, {"status": None}, {"statusCode": 65},
                           {"issues": [{"severity": "error", "message": "Synthetic rejection"}]}):
            with self.subTest(alteration=alteration):
                previous = copy.deepcopy(self.log)
                self.log.update(alteration)
                self.save_log()
                with self.assertRaisesRegex(RuntimeError, "not been accepted"):
                    self.validate_distribution()
                self.log = previous
        self.cdhash.assert_not_called()

    def test_rejects_missing_notarization_log(self):
        (self.submission / "notarization-log.json").unlink()
        with self.assertRaisesRegex(RuntimeError, "no command-line App fallback"):
            self.validate_distribution()

    def test_rejects_submissions_directory_linked_outside_archive(self):
        submissions = self.archive / "Submissions"
        outside = self.root / "external-submissions"
        submissions.rename(outside)
        submissions.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "Submissions must be a real directory"):
            self.validate_distribution()
        self.cdhash.assert_not_called()

    def test_rejects_notarization_log_linked_outside_archive(self):
        log = self.submission / "notarization-log.json"
        outside = self.root / "external-notarization-log.json"
        log.rename(outside)
        log.symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, "notarization log escapes"):
            self.validate_distribution()
        self.cdhash.assert_not_called()

    def test_rejects_different_notarization_job(self):
        self.log["jobId"] = OTHER_ID
        self.save_log()
        with self.assertRaisesRegex(RuntimeError, "job do not match"):
            self.validate_distribution()

    def test_rejects_different_uploaded_build(self):
        self.distribution["uploadedBuildNumber"] = "8"
        self.save_archive_info()
        with self.assertRaisesRegex(RuntimeError, "distribution build does not match"):
            self.validate_distribution()

    def test_rejects_export_or_submission_identity_version_and_build_mismatch(self):
        for app in (self.exported, self.submitted):
            for key, value in (("CFBundleIdentifier", "com.example.synthetic"),
                               ("CFBundleShortVersionString", "1.2.4"), ("CFBundleVersion", "8")):
                with self.subTest(app=app.parent.name, field=key):
                    info = dict(self.app_properties, **{key: value})
                    write_plist(app / "Contents/Info.plist", info)
                    with self.assertRaisesRegex(RuntimeError, "identity, version or build"):
                        self.validate_distribution()
                    write_plist(app / "Contents/Info.plist", self.app_properties)

    def test_rejects_exported_file_modification(self):
        (self.exported / "Contents/Resources/sample.txt").write_text("Changed synthetic resource")
        with self.assertRaisesRegex(RuntimeError, "differs from the accepted"):
            self.validate_distribution()

    def test_rejects_exported_symlink_modification(self):
        alias = self.exported / "Contents/ResourceAlias"
        alias.unlink()
        alias.symlink_to("MacOS", target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "differs from the accepted"):
            self.validate_distribution()

    def test_rejects_exported_file_mode_modification(self):
        (self.exported / "Contents/MacOS/TSX").chmod(0o644)
        with self.assertRaisesRegex(RuntimeError, "differs from the accepted"):
            self.validate_distribution()

    def test_rejects_different_code_hash(self):
        self.cdhash.return_value = "0" * 40
        with self.assertRaisesRegex(RuntimeError, "does not match Apple's notarization ticket"):
            self.validate_distribution()

    def test_rejects_ticket_prefix_collision_and_path_traversal(self):
        for path in ("Other.zip/TSX.app", "TSX.zip/TSX.app-other/file",
                     "TSX.zip/TSX.app/../outside", "TSX.zip/TSX.app/Contents/../../outside"):
            with self.subTest(path=path):
                self.log["ticketContents"] = [self.ticket(path)]
                self.save_log()
                with self.assertRaisesRegex(RuntimeError, "outside|escapes"):
                    self.validate_distribution()
        self.cdhash.assert_not_called()

    def test_rejects_ticket_symlink_escape_even_when_app_manifests_match(self):
        outside = self.root / "outside-code"
        outside.write_bytes(b"synthetic outside executable")
        for app in (self.submitted, self.exported):
            (app / "Contents/Outside").symlink_to(outside)
        self.log["ticketContents"] = [self.ticket("TSX.zip/TSX.app/Contents/Outside")]
        self.save_log()
        with self.assertRaisesRegex(RuntimeError, "path escapes"):
            self.validate_distribution()
        self.cdhash.assert_not_called()

    def test_accepts_internal_symlink_and_consistent_duplicate_tickets(self):
        self.log["ticketContents"].append(self.ticket("TSX.zip/TSX.app/Contents/ResourceAlias/sample.txt"))
        self.log["ticketContents"].append(copy.deepcopy(self.log["ticketContents"][0]))
        self.save_log()
        self.assertEqual(self.validate_distribution()["ticketCount"], 4)

    def test_rejects_empty_tickets_and_missing_root_architecture(self):
        for tickets in ([], [self.ticket()]):
            with self.subTest(ticket_count=len(tickets)):
                self.log["ticketContents"] = tickets
                self.save_log()
                with self.assertRaisesRegex(RuntimeError, "no signing tickets|both App architectures"):
                    self.validate_distribution()

    def test_rejects_invalid_ticket_digest_and_architecture(self):
        for alteration in ({"cdhash": "invalid"}, {"digestAlgorithm": "SHA-1"}, {"arch": "i386"}):
            with self.subTest(alteration=alteration):
                ticket = dict(self.ticket(), **alteration)
                self.log["ticketContents"] = [ticket]
                self.save_log()
                with self.assertRaisesRegex(RuntimeError, "Unsupported notarization signing ticket"):
                    self.validate_distribution()
        self.cdhash.assert_not_called()

    def test_rejects_wrong_team_certificate_or_distribution_channel(self):
        for alteration in ({"teamID": "OTHERTEAM1"}, {"certificateSHA1": "f" * 40},
                           {"destination": "export"}, {"uploadDestination": "App Store Connect"}):
            with self.subTest(alteration=alteration):
                previous = copy.deepcopy(self.distribution)
                self.distribution.update(alteration)
                self.save_archive_info()
                with self.assertRaises(RuntimeError):
                    self.validate_distribution()
                self.distribution.clear()
                self.distribution.update(previous)
        self.cdhash.assert_not_called()


class SourceArchiveTests(ArchiveFixtureTestCase):
    def test_backup_manifest_rejects_external_links_and_preserves_internal_links(self):
        value = evidence.manifest(self.archive, internal_links=True)
        self.assertEqual(value["Products/Applications/TSX.app/Contents/ResourceAlias"],
                         {"type": "symlink", "target": "Resources"})
        outside = self.root / "external-evidence"
        outside.write_text("Synthetic external evidence")
        (self.archive / "linked-evidence").symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, "symlink escapes its self-contained backup"):
            evidence.manifest(self.archive, internal_links=True)

    def test_backup_rejects_absolute_internal_link_that_still_points_to_source(self):
        (self.archive / "absolute-resource").symlink_to(self.product / "Contents/Resources/sample.txt")
        evidence.manifest(self.archive, internal_links=True)
        backup = self.directory / "TSX.xcarchive"
        shutil.copytree(self.archive, backup, symlinks=True)
        with self.assertRaisesRegex(RuntimeError, "symlink escapes its self-contained backup"):
            evidence.manifest(backup, internal_links=True)

    def test_accepts_unchanged_recorded_archive(self):
        self.assertEqual(evidence.validate_source_archive(self.source, self.directory), self.archive)

    def test_rejects_legacy_source_metadata(self):
        for alteration in ({"schema": 1}, {"workflow": "command-line"}):
            with self.subTest(alteration=alteration):
                source = dict(self.source, **alteration)
                with self.assertRaisesRegex(RuntimeError, "legacy"):
                    evidence.validate_source_archive(source, self.directory)

    def test_rejects_changed_archived_product(self):
        (self.product / "Contents/Resources/sample.txt").write_text("Changed original archive resource")
        with self.assertRaisesRegex(RuntimeError, "original archived app changed"):
            evidence.validate_source_archive(self.source, self.directory)

    def test_rejects_changed_manifest_even_when_it_matches_modified_product(self):
        (self.product / "Contents/Resources/sample.txt").write_text("Changed original archive resource")
        write_json(self.directory / "archived-app-manifest.json", evidence.manifest(self.product))
        with self.assertRaisesRegex(RuntimeError, "original archived app changed"):
            evidence.validate_source_archive(self.source, self.directory)

    def test_rejects_changed_application_properties(self):
        self.archive_info["ApplicationProperties"]["Team"] = "OTHERTEAM1"
        self.save_archive_info()
        with self.assertRaisesRegex(RuntimeError, "original application properties changed"):
            evidence.validate_source_archive(self.source, self.directory)

    def test_rejects_archive_outside_standard_archives_directory(self):
        source = dict(self.source, archivePath=str(self.root / "foreign.xcarchive"))
        with self.assertRaisesRegex(RuntimeError, "standard Archives directory"):
            evidence.validate_source_archive(source, self.directory)

    def test_rejects_symlink_archive(self):
        alias = self.archives / "alias.xcarchive"
        alias.symlink_to(self.archive, target_is_directory=True)
        source = dict(self.source, archivePath=str(alias))
        with self.assertRaisesRegex(RuntimeError, "Invalid Xcode archive path"):
            evidence.validate_source_archive(source, self.directory)

    def test_rejects_archived_application_path_escape(self):
        self.archive_info["ApplicationProperties"]["ApplicationPath"] = "../outside.app"
        self.save_archive_info()
        with self.assertRaisesRegex(RuntimeError, "Invalid archived application path"):
            evidence.archive_product(self.archive)


class ReleaseEntryPointTests(OfflineTestCase):
    def test_legacy_app_submit_and_finish_fail_before_any_command(self):
        args = SimpleNamespace(stage="app", directory=self.root / "does-not-exist", profile="fixture-profile")
        for operation in (release.submit, release.finish):
            with self.subTest(operation=operation.__name__):
                with self.assertRaisesRegex(RuntimeError, "App submit/finish is forbidden"):
                    operation(args, {})
        self.command.assert_not_called()
        self.recorded_command.assert_not_called()
        self.process.assert_not_called()

    def test_cli_rejects_app_stage_before_directory_validation_or_commands(self):
        validate = self.patch(evidence, "persistent_directory")
        for command in ("submit", "finish"):
            with self.subTest(command=command):
                with mock.patch.object(sys, "argv", ["release.py", command, "--stage", "app"]), \
                        mock.patch.object(sys, "stderr", new=io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        release.main()
                self.assertEqual(error.exception.code, 2)
        validate.assert_not_called()
        self.command.assert_not_called()
        self.process.assert_not_called()

    def test_prepare_rejects_legacy_release_candidate_without_commands(self):
        write_json(self.root / "release.json", {"state": "app-signed", "version": "1.2.3"})
        args = SimpleNamespace(directory=self.root, app=self.root / "TSX.app", identity=CERTIFICATE)
        with self.assertRaisesRegex(RuntimeError, "legacy App candidates are rejected"):
            release.prepare(args)
        self.command.assert_not_called()
        self.recorded_command.assert_not_called()
        self.process.assert_not_called()

    def test_prepare_rejects_legacy_source_even_with_new_release_state(self):
        source = {"schema": 1, "repository": str(release.ROOT), "commit": "a" * 40,
                  "version": "1.2.3", "build": "7"}
        write_json(self.root / "release.json", {"state": "awaiting-xcode-distribution", "commit": source["commit"],
                                                "version": source["version"], "build": source["build"]})
        write_json(self.root / "source.json", source)
        self.patch(release, "clean_source", return_value=source["commit"])
        args = SimpleNamespace(directory=self.root, app=self.root / "TSX.app", identity=CERTIFICATE)
        with self.assertRaisesRegex(RuntimeError, "legacy command-line App notarization"):
            release.prepare(args)
        self.command.assert_not_called()
        self.recorded_command.assert_not_called()
        self.process.assert_not_called()

    def test_prepare_rejects_release_version_or_build_mismatch_before_commands(self):
        source = {"schema": 2, "workflow": "xcode-organizer", "repository": str(release.ROOT),
                  "commit": "a" * 40, "version": "1.2.3", "build": "7"}
        write_json(self.root / "source.json", source)
        args = SimpleNamespace(directory=self.root, app=self.root / "TSX.app", identity=CERTIFICATE)
        for alteration in ({"version": "1.2.4"}, {"build": "8"}):
            with self.subTest(alteration=alteration):
                metadata = dict(source, state="awaiting-xcode-distribution", **alteration)
                write_json(self.root / "release.json", metadata)
                with self.assertRaisesRegex(RuntimeError, "version and build differ"):
                    release.prepare(args)
        self.command.assert_not_called()
        self.recorded_command.assert_not_called()
        self.process.assert_not_called()


class DmgNotarizationTests(OfflineTestCase):
    def setUp(self):
        super().setUp()
        self.asset = self.root / "TSX-1.2.3-macOS-universal.dmg"
        self.asset.write_bytes(b"synthetic disk image; not mountable")
        self.metadata = {
            "schema": 2, "workflow": "xcode-organizer", "xcodeSubmissionID": SUBMISSION_ID,
            "state": "app-notarized-dmg-signed", "dmg": self.asset.name,
            "submittedDmgSHA256": evidence.sha(self.asset), "version": "1.2.3", "build": "7",
        }
        self.args = SimpleNamespace(directory=self.root, stage="dmg", profile="fixture-profile")
        self.status_result = {"id": OTHER_ID, "status": "Accepted"}
        self.log_result = {
            "jobId": OTHER_ID, "status": "Accepted", "sha256": self.metadata["submittedDmgSHA256"],
            "archiveFilename": self.asset.name,
        }

    def record_submission(self):
        write_json(self.root / "notary-dmg.json", {"id": OTHER_ID})

    def test_rejects_submit_or_finish_for_legacy_candidate(self):
        metadata = dict(self.metadata, schema=1)
        for operation in (release.submit, release.finish):
            with self.subTest(operation=operation.__name__):
                with self.assertRaisesRegex(RuntimeError, "legacy App candidates are rejected"):
                    operation(self.args, metadata)
        self.command.assert_not_called()

    def test_rejects_repeated_submit_with_record_or_attempt(self):
        for filename in ("notary-dmg.json", "notary-dmg-attempt.json"):
            with self.subTest(filename=filename):
                marker = self.root / filename
                write_json(marker, {"id": OTHER_ID})
                with self.assertRaisesRegex(RuntimeError, "already recorded or attempted"):
                    release.submit(self.args, self.metadata)
                marker.unlink()
        self.command.assert_not_called()
        self.process.assert_not_called()

    def test_submission_attempt_is_persisted_before_upload_and_prevents_retry(self):
        def interrupted_upload(*args, **kwargs):
            self.assertEqual(args[:3], ("xcrun", "notarytool", "submit"))
            attempt = json.loads((self.root / "notary-dmg-attempt.json").read_text())
            self.assertEqual(attempt["sha256"], self.metadata["submittedDmgSHA256"])
            self.assertEqual(attempt["asset"], self.asset.name)
            raise RuntimeError("Synthetic interrupted upload")

        self.command.side_effect = interrupted_upload
        with self.assertRaisesRegex(RuntimeError, "Synthetic interrupted upload"):
            release.submit(self.args, self.metadata)
        with self.assertRaisesRegex(RuntimeError, "already recorded or attempted"):
            release.submit(self.args, self.metadata)
        self.assertEqual(self.command.call_count, 1)
        self.assertFalse((self.root / "notary-dmg.json").exists())

    def test_rejects_changed_dmg_before_upload(self):
        self.asset.write_bytes(b"changed synthetic disk image")
        with self.assertRaisesRegex(RuntimeError, "Notarization input changed"):
            release.submit(self.args, self.metadata)
        self.command.assert_not_called()
        self.assertFalse((self.root / "notary-dmg-attempt.json").exists())

    def test_accepted_status_only_queries_info_and_log(self):
        self.record_submission()
        self.command.side_effect = [json.dumps(self.status_result), json.dumps(self.log_result)]
        with mock.patch.object(sys, "stdout", new=io.StringIO()):
            current = release.status(self.args, self.metadata)
        self.assertEqual(current, self.status_result)
        self.assertEqual([call.args[2] for call in self.command.call_args_list], ["info", "log"])
        self.assertEqual(json.loads((self.root / "notary-dmg-log.json").read_text()), self.log_result)
        self.assertFalse((self.root / "notary-dmg-attempt.json").exists())
        self.recorded_command.assert_not_called()

    def test_pending_status_does_not_fetch_log_or_upload(self):
        self.record_submission()
        self.command.side_effect = [json.dumps({"id": OTHER_ID, "status": "In Progress"})]
        with mock.patch.object(sys, "stdout", new=io.StringIO()):
            release.status(self.args, self.metadata)
        self.assertEqual([call.args[2] for call in self.command.call_args_list], ["info"])
        self.assertFalse((self.root / "notary-dmg-log.json").exists())

    def test_rejects_status_for_different_submission(self):
        self.record_submission()
        self.command.side_effect = [json.dumps({"id": SUBMISSION_ID, "status": "Accepted"})]
        with self.assertRaisesRegex(RuntimeError, "different submission"):
            release.status(self.args, self.metadata)
        self.assertEqual([call.args[2] for call in self.command.call_args_list], ["info"])

    def test_rejects_log_for_different_job_hash_filename_or_status(self):
        self.record_submission()
        for alteration in ({"jobId": SUBMISSION_ID}, {"sha256": "0" * 64},
                           {"archiveFilename": "Other.dmg"}, {"status": "Invalid"}):
            with self.subTest(alteration=alteration):
                self.command.reset_mock()
                self.command.side_effect = [json.dumps(self.status_result), json.dumps(dict(self.log_result, **alteration))]
                with self.assertRaisesRegex(RuntimeError, "does not match the submitted DMG"):
                    release.status(self.args, self.metadata)
                self.assertEqual([call.args[2] for call in self.command.call_args_list], ["info", "log"])

    def test_finish_can_retry_after_appcast_failure_without_changing_submitted_dmg(self):
        self.patch(release, "status", return_value=self.status_result)
        original = self.asset.read_bytes()
        attempts = []

        def staple_copy(directory, name, *args):
            target = Path(args[-1])
            self.assertNotEqual(target, self.asset)
            if name == "dmg-staple":
                target.write_bytes(target.read_bytes() + b"; synthetic stapled ticket")
                attempts.append(directory)
            (directory / (name + ".log")).write_text("Synthetic successful verification")

        generated = 0

        def generate_artifacts(*args, **kwargs):
            nonlocal generated
            if Path(args[0]).name == "generate_appcast":
                generated += 1
                if generated == 1:
                    raise RuntimeError("Synthetic appcast failure after successful stapling")
                (Path(args[-1]) / "appcast.xml").write_text("Synthetic signed appcast")
            else:
                self.assertEqual(Path(args[0]).name, "sign_update")

        self.recorded_command.side_effect = staple_copy
        self.command.side_effect = generate_artifacts
        with self.assertRaisesRegex(RuntimeError, "Synthetic appcast failure"):
            release.finish(self.args, self.metadata)
        self.assertEqual(self.asset.read_bytes(), original)
        self.assertEqual(self.metadata["state"], "app-notarized-dmg-signed")
        self.assertFalse((self.root / "artifacts").exists())
        with mock.patch.object(sys, "stdout", new=io.StringIO()):
            release.finish(self.args, self.metadata)
        self.assertEqual(self.asset.read_bytes(), original)
        self.assertEqual(evidence.sha(self.asset), self.metadata["submittedDmgSHA256"])
        self.assertEqual(len(set(attempts)), 2)
        self.assertTrue((attempts[0] / "artifacts" / self.asset.name).exists())
        self.assertTrue(all((attempt / "dmg-staple.log").exists() for attempt in attempts))
        final = self.root / "artifacts" / self.asset.name
        self.assertNotEqual(final.read_bytes(), original)
        self.assertEqual(self.metadata["dmgSHA256"], evidence.sha(final))
        self.assertEqual(self.metadata["state"], "notarized-ready-for-install-test")
        self.assertEqual((final.parent / "SHA256SUMS.txt").read_text(),
                         f"{evidence.sha(final)}  {self.asset.name}\n")
        self.assertFalse((self.root / "notary-dmg-attempt.json").exists())
        self.process.assert_not_called()


if __name__ == "__main__":
    unittest.main()
