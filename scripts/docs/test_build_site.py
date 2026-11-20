#!/usr/bin/env python3
"""Focused tests for public-site link rewriting and boundary enforcement."""

import unittest
import tempfile
from pathlib import Path

import build_site
import prepare_publication


class SiteAssemblyTests(unittest.TestCase):
    def test_internal_markdown_links_rewrite_to_rendered_pages(self):
        source = "[Navigation](navigation.md#routes)"
        self.assertEqual(
            "[Navigation](navigation.html#routes)",
            build_site.rewrite_links(source, "ai.md", {"navigation.md"}),
        )

    def test_external_and_anchor_links_remain_unchanged(self):
        source = "[external](https://example.test/a.md) [section](#routes)"
        self.assertEqual(source, build_site.rewrite_links(source, "ai.md", set()))

    def test_links_to_unpublished_pages_fail(self):
        with self.assertRaises(SystemExit):
            build_site.rewrite_links("[plan](plans/notes.md)", "guide.md", {"guide.md"})

    def test_source_reference_check_catches_engine_paths(self):
        self.assertIsNotNone(build_site.INTERNAL_PATH.search("See src/engine/core/context.zig."))

    def test_source_reference_check_catches_game_paths(self):
        self.assertIsNotNone(build_site.INTERNAL_PATH.search("See src/game/enemy.zig."))

    def test_code_example_includes_expand_from_examples_directory(self):
        output = build_site.expand_code_examples(
            "<!-- include-code: examples/api_basics.zig -->",
            "application-lifecycle.md",
        )
        self.assertIn("```zig\nconst std = @import(\"std\");", output)
        self.assertNotIn("include-code", output)

    def test_code_example_includes_reject_paths_outside_examples(self):
        with self.assertRaises(SystemExit):
            build_site.expand_code_examples(
                "<!-- include-code: docs/README.md -->",
                "application-lifecycle.md",
            )

    def test_package_and_api_versions_must_match(self):
        package = '.version = "0.3.0",'
        source = "pub const version: Version = .{ .major = 0, .minor = 3, .patch = 0 };"
        self.assertEqual("0.3.0", build_site.parse_engine_version(package, source))
        with self.assertRaises(SystemExit):
            build_site.parse_engine_version(package, source.replace(".patch = 0", ".patch = 1"))

    def test_rendered_site_checks_local_links_and_anchors(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "api").mkdir()
            (root / "guides").mkdir()
            (root / "index.html").write_text(
                '<a href="/Bairava-Engine/api/">API</a>\n'
                '<a href="guides/start.html#setup">Guide</a>',
                encoding="utf-8",
            )
            (root / "api" / "index.html").write_text("<h1 id=\"api\">API</h1>", encoding="utf-8")
            (root / "guides" / "start.html").write_text("<h1 id=\"setup\">Setup</h1>", encoding="utf-8")
            (root / "404.html").write_text("<h1>Not found</h1>", encoding="utf-8")
            (root / "search-index.json").write_text('[{"url":"/api/"}]', encoding="utf-8")
            build_site.validate_rendered_site(root)

            (root / "guides" / "start.html").write_text("<h1>Setup</h1>", encoding="utf-8")
            with self.assertRaises(SystemExit):
                build_site.validate_rendered_site(root)

    def test_site_cleanup_removes_stale_generated_pages_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "guides").mkdir()
            (root / "guides" / "stale.md").write_text("stale", encoding="utf-8")
            (root / "_api_source.md").write_text("generated input", encoding="utf-8")
            (root / "custom.txt").write_text("not owned by the site builder", encoding="utf-8")
            previous_output = build_site.OUTPUT
            try:
                build_site.OUTPUT = root
                build_site.clear_generated_site()
            finally:
                build_site.OUTPUT = previous_output
            self.assertFalse((root / "guides").exists())
            self.assertTrue((root / "_api_source.md").is_file())
            self.assertTrue((root / "custom.txt").is_file())

    def test_publication_creates_dev_and_release_variants(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            (source / "_data").mkdir(parents=True)
            (source / "_data" / "site.json").write_text(
                '{"engine_version":"0.3.0","source_commit":"' + "a" * 40 + '"}',
                encoding="utf-8",
            )
            (source / "_config.yml").write_text("baseurl: /Bairava-Engine\n", encoding="utf-8")
            archive = root / "archive"
            sources = root / "variants"
            site = root / "published"

            branch = prepare_publication.prepare(source, archive, sources, site, "branch", "main")
            self.assertEqual("true", branch["build_dev"])
            self.assertIn("baseurl: /Bairava-Engine/dev", (sources / "dev" / "_config.yml").read_text(encoding="utf-8"))
            self.assertIn("/Bairava-Engine/dev/", (site / "index.html").read_text(encoding="utf-8"))

            release = prepare_publication.prepare(source, archive, sources, site, "tag", "v0.3.0")
            self.assertEqual("true", release["build_release"])
            self.assertEqual("true", release["build_latest"])
            self.assertIn("baseurl: /Bairava-Engine/0.3.0", (sources / "release" / "_config.yml").read_text(encoding="utf-8"))
            self.assertIn("baseurl: /Bairava-Engine/latest", (sources / "latest" / "_config.yml").read_text(encoding="utf-8"))

    def test_publication_preserves_immutable_release_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            metadata = source / "_data"
            metadata.mkdir(parents=True)
            commit = "b" * 40
            (metadata / "site.json").write_text(
                '{"engine_version":"0.3.0","source_commit":"' + commit + '"}',
                encoding="utf-8",
            )
            (source / "_config.yml").write_text("baseurl: /Bairava-Engine\n", encoding="utf-8")
            archive = root / "archive"
            release_data = archive / "0.3.0" / "_data"
            latest_data = archive / "latest" / "_data"
            release_data.mkdir(parents=True)
            latest_data.mkdir(parents=True)
            for path in (release_data / "site.json", latest_data / "site.json"):
                path.write_text(
                    '{"engine_version":"0.3.0","source_commit":"' + commit + '"}',
                    encoding="utf-8",
                )
            result = prepare_publication.prepare(
                source,
                archive,
                root / "variants",
                root / "published",
                "tag",
                "v0.3.0",
            )
            self.assertEqual("false", result["build_release"])
            self.assertEqual("false", result["build_latest"])

            (metadata / "site.json").write_text(
                '{"engine_version":"0.3.0","source_commit":"' + "c" * 40 + '"}',
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                prepare_publication.prepare(
                    source,
                    archive,
                    root / "variants",
                    root / "published",
                    "tag",
                    "v0.3.0",
                )

    def test_publication_does_not_move_latest_backward(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            metadata = source / "_data"
            metadata.mkdir(parents=True)
            (metadata / "site.json").write_text(
                '{"engine_version":"0.3.0","source_commit":"' + "a" * 40 + '"}',
                encoding="utf-8",
            )
            (source / "_config.yml").write_text("baseurl: /Bairava-Engine\n", encoding="utf-8")
            archive = root / "archive"
            latest_data = archive / "latest" / "_data"
            latest_data.mkdir(parents=True)
            (latest_data / "site.json").write_text(
                '{"engine_version":"0.4.0","source_commit":"' + "b" * 40 + '"}',
                encoding="utf-8",
            )
            result = prepare_publication.prepare(
                source,
                archive,
                root / "variants",
                root / "published",
                "tag",
                "v0.3.0",
            )
            self.assertEqual("true", result["build_release"])
            self.assertEqual("false", result["build_latest"])
            self.assertTrue((root / "published" / "latest" / "_data" / "site.json").is_file())

    def test_release_tag_must_match_documented_engine_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            metadata = source / "_data"
            metadata.mkdir(parents=True)
            (metadata / "site.json").write_text(
                '{"engine_version":"0.3.0","source_commit":"' + "a" * 40 + '"}',
                encoding="utf-8",
            )
            (source / "_config.yml").write_text("baseurl: /Bairava-Engine\n", encoding="utf-8")
            with self.assertRaises(SystemExit):
                prepare_publication.prepare(
                    source,
                    root / "archive",
                    root / "variants",
                    root / "published",
                    "tag",
                    "v0.2.0",
                )

    def test_published_site_checks_version_selector_and_subsite_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "dev" / "api").mkdir(parents=True)
            (root / "index.html").write_text(
                '<a href="/Bairava-Engine/dev/">Development</a>',
                encoding="utf-8",
            )
            (root / "dev" / "index.html").write_text(
                '<a href="/Bairava-Engine/dev/api/">API</a>',
                encoding="utf-8",
            )
            (root / "dev" / "api" / "index.html").write_text("<h1 id=\"api\">API</h1>", encoding="utf-8")
            (root / "dev" / "404.html").write_text("<h1>Not found</h1>", encoding="utf-8")
            (root / "dev" / "search-index.json").write_text('[{"url":"/api/"}]', encoding="utf-8")
            build_site.validate_publication(root)


if __name__ == "__main__":
    unittest.main()
