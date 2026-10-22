"""HTTP asset boundaries and portable verification reports (stdlib only)."""
import copy
import functools
import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock

if __package__:
    from .reporting import portable_report
    from .serve import DevelopmentHandler, LoopbackHTTPServer
else:
    from reporting import portable_report
    from serve import DevelopmentHandler, LoopbackHTTPServer


class PortableReportTests(unittest.TestCase):
    def test_project_prefixes_and_file_urls_are_replaced_recursively(self):
        root = Path.cwd().resolve()
        report = {"command": [str(root / "sdk/index.mjs"), (root / "sdk/index.mjs").as_posix()],
                  "nested": [{"url": (root / "sdk/index.mjs").as_uri()}],
                  "diagnostic": json.dumps(str(root), ensure_ascii=False)}
        original = copy.deepcopy(report)
        result = portable_report(report, root)
        self.assertEqual(report, original)
        self.assertTrue(all(value.startswith("<project>") for value in result["command"]))
        self.assertEqual(result["nested"][0]["url"], "<project>/sdk/index.mjs")
        self.assertNotIn(str(root), json.dumps(result))

    def test_tool_executables_keep_roles_instead_of_install_locations(self):
        root = Path.cwd().resolve()
        tool = root / "_build/toolchain/bin/moon"
        result = portable_report({"args": [str(tool), "test"], "version": str(tool) + " v1"}, root, [("moon", tool)])
        self.assertEqual(result, {"args": ["<moon>", "test"], "version": "<moon> v1"})

    def test_home_and_abbreviated_project_paths_are_replaced(self):
        home = Path.home().resolve()
        root = home / "sample-project"
        result = portable_report({"cache": str(home / ".cache/item"),
                                  "version": "~/sample-project/bin/moon ~\\sample-project\\bin\\moon"}, root)
        self.assertTrue(result["cache"].startswith("<home>"))
        self.assertEqual(result["version"], "<project>/bin/moon <project>\\bin\\moon")

    def test_scores_csv_urls_and_synthetic_path_inputs_are_preserved(self):
        report = {"score": -1.5, "ok": True, "result": None,
                  "response": {"RESPONSE": "C:/drive"}, "path_case": "../escape",
                  "source": "https://www.1edtech.org/standards/qti/index",
                  "csv": 'line,score\r\n1,-1.5\r\n2,\r\n'}
        self.assertEqual(portable_report(report, Path.cwd()), report)

    def test_tuple_records_are_also_converted_before_json_export(self):
        root = Path.cwd().resolve()
        self.assertEqual(portable_report((str(root), {"file": str(root / "sample.xml")}), root),
                         ["<project>", {"file": "<project>" + str(root / "sample.xml")[len(str(root)):]}])


class PublicAssetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="qti-http-")
        cls.root = Path(cls.temporary.name).resolve()
        fixtures = {"web/index.html": "<html>workbench</html>", "web/app.mjs": "export const publicAsset = true;",
                    "sdk/index.mjs": "export const sdk = true;", "sdk/qti-core.mjs": "export const core = true;",
                    "examples/sample.xml": "<item/>", "web/sample-package.zip": "public-zip",
                    "README.md": "Public usage", ".git/HEAD": "PRIVATE_SENTINEL",
                    "_build/validation.json": "PRIVATE_SENTINEL", ".mooncakes/private": "PRIVATE_SENTINEL",
                    "tools/project.py": "PRIVATE_SENTINEL", "sdk/node_modules/private.js": "PRIVATE_SENTINEL",
                    "private.md": "PRIVATE_SENTINEL"}
        for name, text in fixtures.items():
            path = cls.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")

        class QuietHandler(DevelopmentHandler):
            def log_message(self, *args):
                pass

        handler = functools.partial(QuietHandler, directory=str(cls.root))
        cls.server = LoopbackHTTPServer(("127.0.0.1", 0), handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join(timeout=5)
        cls.server.server_close()
        if cls.root.parent != Path(tempfile.gettempdir()).resolve() or not cls.root.name.startswith("qti-http-"):
            raise AssertionError("Unexpected temporary test directory")
        cls.temporary.cleanup()

    def request(self, path, method="GET", headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            connection.request(method, path, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_public_page_sdk_examples_and_packages_remain_available(self):
        for path in ["/web/", "/web/app.mjs", "/sdk/index.mjs?v=1", "/sdk/qti-core.mjs",
                     "/examples/sample.xml", "/web/sample-package.zip", "/README.md"]:
            with self.subTest(path=path):
                status, headers, body = self.request(path)
                self.assertEqual(status, 200)
                self.assertNotIn(b"PRIVATE_SENTINEL", body)
                self.assertEqual(headers["Cache-Control"], "no-store")
                self.assertEqual(headers["X-Content-Type-Options"], "nosniff")

    def test_root_redirects_to_workbench_without_a_directory_listing(self):
        status, headers, body = self.request("/")
        self.assertEqual(status, 302)
        self.assertEqual(headers["Location"], "/web/")
        self.assertEqual(body, b"")

    def test_private_files_and_directory_indexes_are_not_served(self):
        for method in ["GET", "HEAD"]:
            for path in ["/.git/HEAD", "/_build/validation.json", "/.mooncakes/private", "/tools/project.py",
                         "/sdk/node_modules/private.js", "/private.md", "/examples/", "/sdk/", "/web/bridge/"]:
                with self.subTest(path=path, method=method):
                    status, _, body = self.request(path, method)
                    self.assertEqual(status, 404)
                    self.assertNotIn(b"PRIVATE_SENTINEL", body)
                    self.assertNotIn(str(self.root).encode(), body)

    def test_encoded_traversal_and_malformed_paths_do_not_bypass_the_boundary(self):
        for path in ["/web/../.git/HEAD", "/web/%2e%2e/_build/validation.json", "/%2egit/HEAD",
                     "/web%5c..%5c.git/HEAD", "/web/%252e%252e/.git/HEAD", "/examples/a%00.xml",
                     "/examples/%ff.xml", "/examples/sample.xml:private.xml", "/web/missing.mjs"]:
            with self.subTest(path=path):
                status, _, body = self.request(path)
                self.assertEqual(status, 404)
                self.assertNotIn(b"PRIVATE_SENTINEL", body)
        self.assertEqual(self.request("/web/%61pp.mjs")[0], 200)

    def test_head_and_conditional_requests_get_fresh_public_assets(self):
        status, headers, body = self.request("/web/app.mjs", "HEAD", {"If-Modified-Since": "Fri, 01 Jan 2100 00:00:00 GMT"})
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertGreater(int(headers["Content-Length"]), 0)

    def test_missing_entry_point_does_not_fall_back_to_listing(self):
        entry = self.root / "web/index.html"
        saved = entry.read_bytes()
        try:
            entry.unlink()
            self.assertEqual(self.request("/web/")[0], 404)
        finally:
            entry.write_bytes(saved)

    def test_resolved_assets_cannot_redirect_to_a_private_or_external_path(self):
        resolve = Path.resolve
        for destination in [self.root / "_build/validation.json", self.root.parent / "outside.xml"]:
            def redirect(path, *args, **kwargs):
                if path == self.root / "web/app.mjs":
                    return destination
                return resolve(path, *args, **kwargs)
            with self.subTest(destination=destination.name), mock.patch.object(Path, "resolve", redirect):
                self.assertEqual(self.request("/web/app.mjs")[0], 404)

    def test_directory_entry_point_cannot_redirect_to_a_private_or_external_path(self):
        resolve = Path.resolve
        for destination in [self.root / "private.md", self.root.parent / "outside.html"]:
            def redirect(path, *args, **kwargs):
                if path == self.root / "web/index.html":
                    return destination
                return resolve(path, *args, **kwargs)
            with self.subTest(destination=destination.name), mock.patch.object(Path, "resolve", redirect):
                for method in ["GET", "HEAD"]:
                    for path in ["/web", "/web/", "/web/index.html"]:
                        self.assertEqual(self.request(path, method)[0], 404)


if __name__ == "__main__":
    unittest.main()
