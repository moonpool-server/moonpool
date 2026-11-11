#!/usr/bin/env python3
# Deterministic fake CurseForge API and CDN responses keep these tests offline.
"""What the publisher reads out of an archive, and the policies it holds to."""
import hashlib
import http.server
import importlib.util
import io
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock
import zipfile

ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("publish_mods", ROOT / "scripts/publish-mods.py")
PUBLISH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUBLISH)


class Response(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *_args): self.close()


def zip_of(path, members):
    with zipfile.ZipFile(path, "w") as bundle:
        for name in members:
            bundle.writestr(name, name.encode())
    return path


class ArchiveRootsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self): self.temp.cleanup()

    def test_a_zip_that_is_one_ue4ss_mod_has_one_root(self):
        roots = PUBLISH.archive_roots(zip_of(self.root / "a.zip", ["Scripts/main.lua", "readme.md"]), "ue4ss")
        self.assertEqual(roots, [{"name": "", "prefix": "", "native": False}])

    def test_nested_mods_are_found_by_their_main_file(self):
        roots = PUBLISH.archive_roots(zip_of(self.root / "b.zip",
                                             ["Mods/Voice/Scripts/main.lua", "Mods/Voice/Scripts/lib.lua",
                                              "Mods/Cap/dlls/main.dll", "Mods/Cap/enabled.txt"]), "ue4ss")
        self.assertEqual(roots, [{"name": "Voice", "prefix": "Mods/Voice", "native": False}, {"name": "Cap", "prefix": "Mods/Cap", "native": True}])

    def test_a_pak_trio_is_one_root_and_an_incomplete_one_is_refused(self):
        roots = PUBLISH.archive_roots(zip_of(self.root / "c.zip", ["Fov.pak", "Fov.ucas", "Fov.utoc"]), "pak")
        self.assertEqual(roots, [{"name": "Fov", "prefix": "Fov"}])
        with self.assertRaisesRegex(ValueError, "incomplete"):
            PUBLISH.archive_roots(zip_of(self.root / "d.zip", ["Fov.pak", "Fov.ucas"]), "pak")

    def test_a_folder_of_trios_is_one_mod_and_is_chosen_by_itself(self):
        members = [f"Better Vehicles/0000_BV{n}_P{ext}" for n in ("", "II", "III") for ext in (".pak", ".ucas", ".utoc")]
        roots = PUBLISH.archive_roots(zip_of(self.root / "g.zip", members), "pak")
        self.assertIn({"name": "Better Vehicles", "prefix": "Better Vehicles", "group": True}, roots)
        self.assertEqual(PUBLISH.choose_root(roots, {}, "Better Vehicles")["prefix"], "Better Vehicles")
        two = zip_of(self.root / "h.zip", ["A/x.pak", "A/x.ucas", "A/x.utoc", "A/y.pak", "A/y.ucas", "A/y.utoc",
                                           "B/z.pak", "B/z.ucas", "B/z.utoc", "B/w.pak", "B/w.ucas", "B/w.utoc"])
        with self.assertRaisesRegex(ValueError, "set install.folder"):
            PUBLISH.choose_root(PUBLISH.archive_roots(two, "pak"), {}, "Two sets")

    def test_a_path_that_climbs_out_is_refused(self):
        with self.assertRaisesRegex(ValueError, "unsafe path"):
            PUBLISH.archive_roots(zip_of(self.root / "e.zip", ["../Scripts/main.lua"]), "ue4ss")

    def test_a_lowercase_scripts_folder_is_a_mod_too(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "ct.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("Subnautica2ComfortTweaks/scripts/main.lua", b"print(1)")
                bundle.writestr("Subnautica2ComfortTweaks/scripts/config.lua", b"return {}")
            self.assertEqual(PUBLISH.archive_roots(archive, "ue4ss"),
                             [{"name": "Subnautica2ComfortTweaks", "prefix": "Subnautica2ComfortTweaks", "native": False}])

    def test_a_mod_with_a_dll_is_marked_native(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "n.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("ProxChat/Scripts/main.lua", b"print(1)")
                bundle.writestr("ProxChat/native/proxchat_native.dll", b"MZ")
            self.assertEqual(PUBLISH.archive_roots(archive, "ue4ss"), [{"name": "ProxChat", "prefix": "ProxChat", "native": True}])

    def test_several_roots_need_install_folder(self):
        roots = [{"name": "A", "prefix": "A"}, {"name": "B", "prefix": "B"}]
        with self.assertRaisesRegex(ValueError, "install.folder"):
            PUBLISH.choose_root(roots, {}, "Bundle")
        self.assertEqual(PUBLISH.choose_root(roots, {"folder": "B"}, "Bundle"), roots[1])
        with self.assertRaisesRegex(ValueError, "not in the archive"):
            PUBLISH.choose_root(roots, {"folder": "C"}, "Bundle")


class InstallUrlTests(unittest.TestCase):
    def test_a_github_release_link_fills_repo_tag_and_asset(self):
        install = PUBLISH.install_from_url({"url": "https://github.com/a/b/releases/download/v2.9/More%20Slots.zip"}, "X")
        self.assertEqual((install["type"], install["repo"], install["tag"], install["asset"]), ("github", "a/b", "v2.9", "More Slots.zip"))

    def test_a_curseforge_file_link_fills_slug_and_file_id_and_the_project_is_found_by_slug(self):
        install = PUBLISH.install_from_url({"url": "https://www.curseforge.com/subnautica-2/ue4ss-mods/simple-minimap/files/8164990"}, "X")
        self.assertEqual((install["type"], install["slug"], install["file_id"]), ("curseforge", "simple-minimap", 8164990))
        calls = []

        def fake_get(path, _key):
            calls.append(path)
            if path.startswith("/mods/search?"):
                return [{"id": 77, "slug": "simple-minimap"}]
            if path == "/mods/77":
                return {"allowModDistribution": False, "links": {"websiteUrl": "https://curseforge.test/simple-minimap"}}
            if path == "/mods/77/files/8164990":
                return {"id": 8164990, "fileName": "map.zip", "fileLength": 1, "isAvailable": True,
                        "hashes": [{"algo": 1, "value": "0" * 40}]}
            raise AssertionError(path)
        with mock.patch.object(PUBLISH, "cf_get", fake_get):
            source, _ = PUBLISH.resolve_curseforge({}, install, "k", Path("."), "X", "ue4ss")
        self.assertEqual(install["project_id"], 77)
        self.assertEqual(calls[0], f"/mods/search?gameId={PUBLISH.CF_GAME_ID}&slug=simple-minimap")
        self.assertEqual(source["page"], "https://curseforge.test/simple-minimap")

    def test_a_nexus_file_link_fills_mod_and_file_ids(self):
        install = PUBLISH.install_from_url({"url": "https://www.nexusmods.com/subnautica2/mods/196?tab=files&file_id=1234"}, "X")
        self.assertEqual((install["type"], install["mod_id"], install["file_id"]), ("nexus", 196, 1234))

    def test_explicit_fields_win_and_other_links_are_refused(self):
        install = PUBLISH.install_from_url({"url": "https://github.com/a/b/releases/download/v1/x.zip", "tag": "v2"}, "X")
        self.assertEqual(install["tag"], "v2")
        with self.assertRaisesRegex(ValueError, "not a link this reads"):
            PUBLISH.install_from_url({"url": "https://www.curseforge.com/subnautica-2/ue4ss-mods/simple-minimap"}, "X")


class GitHubPinTests(unittest.TestCase):
    def test_bytes_that_change_under_a_tag_are_refused_until_repinned(self):
        with tempfile.TemporaryDirectory() as tmp:
            temp_dir = Path(tmp)
            install = {"type": "github", "repo": "a/b", "tag": "v1", "asset": "x.zip"}
            bodies = iter([b"first", b"second", b"second"])

            def fake_fetch(_url, dest, headers=None):
                Path(dest).write_bytes(next(bodies))
            pins = {}
            with mock.patch.object(PUBLISH, "fetch", fake_fetch):
                PUBLISH.resolve_github({}, install, pins, temp_dir, "X")
                first = pins["github:a/b@v1/x.zip"]["sha256"]
                self.assertEqual(first, hashlib.sha256(b"first").hexdigest())
                with self.assertRaisesRegex(ValueError, "changed"):
                    PUBLISH.resolve_github({}, install, pins, temp_dir, "X")
                pins["github:a/b@v1/x.zip"]["sha256"] = hashlib.sha256(b"second").hexdigest()
                source, _archive = PUBLISH.resolve_github({}, install, pins, temp_dir, "X")
                self.assertEqual(source["hashes"][0]["value"], hashlib.sha256(b"second").hexdigest())


class CurseForgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("Example/Scripts/main.lua", b"print(1)")
        self.body = archive.getvalue()
        self.sha1 = hashlib.sha1(self.body).hexdigest()

    def tearDown(self): self.temp.cleanup()

    def fake_get(self, path, _key):
        if path == "/mods/123":
            return {"allowModDistribution": self.allowed, "links": {"websiteUrl": "https://curseforge.test/example"}}
        if path == "/mods/123/files/456":
            return {"id": 456, "fileName": "example.zip", "fileLength": len(self.body), "isAvailable": True,
                    "downloadUrl": "https://edge.forgecdn.net/example.zip", "hashes": [{"algo": 1, "value": self.sha1}]}
        raise AssertionError(path)

    def resolve(self, allowed=True, body=None):
        self.allowed = allowed
        install = {"type": "curseforge", "project_id": 123, "file_id": 456}
        with mock.patch.object(PUBLISH, "cf_get", self.fake_get), \
             mock.patch.object(PUBLISH.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = Response(self.body if body is None else body)
            return PUBLISH.resolve_curseforge({}, install, "secret", self.root, "Example", "ue4ss")

    def test_a_distributable_file_is_fetched_and_verified(self):
        source, archive = self.resolve()
        self.assertTrue(source["allow_mod_distribution"])
        self.assertEqual(source["url"], "https://edge.forgecdn.net/example.zip")
        self.assertEqual(PUBLISH.archive_roots(archive, "ue4ss"), [{"name": "Example", "prefix": "Example", "native": False}])
        self.assertEqual(source["hashes"][0], {"algorithm": "sha256", "value": hashlib.sha256(self.body).hexdigest()})
        self.assertEqual([h["algorithm"] for h in source["hashes"]], ["sha256", "sha1"])

    def test_a_non_distributable_file_is_a_page_the_player_downloads_from(self):
        source, archive = self.resolve(False)
        self.assertIsNone(archive)
        self.assertEqual(source["url"], "")
        self.assertEqual(source["page"], "https://curseforge.test/example")

    def test_a_hash_mismatch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "failed its sha1 check"):
            self.resolve(body=b"not the archive")

    def test_latest_is_never_a_pin(self):
        with mock.patch.object(PUBLISH, "cf_get", self.fake_get):
            self.allowed = True
            with self.assertRaisesRegex(ValueError, "file_id is required"):
                PUBLISH.resolve_curseforge({}, {"type": "curseforge", "project_id": 123}, "k", self.root, "Example", "ue4ss")


class CurseForgeKeyTests(unittest.TestCase):
    def test_only_curseforges_own_https_hosts_may_receive_the_key(self):
        for url in ("https://edge.forgecdn.net/f.zip", "https://www.curseforge.com/f.zip"):
            PUBLISH.check_cf_host(url)
        for url in ("http://edge.forgecdn.net/f.zip", "https://forgecdn.net.evil.example/f.zip",
                    "https://evilforgecdn.net/f.zip", "https://evil.example/f.zip",
                    "https://edge.forgecdn.net@evil.example/f.zip"):
            with self.subTest(url), self.assertRaisesRegex(ValueError, "refusing"):
                PUBLISH.check_cf_host(url)

    def test_a_redirect_is_held_to_the_same_hosts(self):
        request = PUBLISH.urllib.request.Request("https://www.curseforge.com/f.zip", headers={"x-api-key": "secret"})
        handler = PUBLISH.CurseForgeRedirects()
        kept = handler.redirect_request(request, None, 302, "Found", {}, "https://edge.forgecdn.net/f.zip")
        self.assertEqual(kept.full_url, "https://edge.forgecdn.net/f.zip")
        for url in ("https://evil.example/f.zip", "http://edge.forgecdn.net/f.zip"):
            with self.subTest(url), self.assertRaisesRegex(ValueError, "refusing"):
                handler.redirect_request(request, None, 302, "Found", {}, url)

    def test_a_real_redirect_to_another_host_never_carries_the_key(self):
        seen = []

        class Elsewhere(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append(self.headers.get("x-api-key"))
                self.send_response(200)
                self.end_headers()

            def log_message(self, *_args): pass

        elsewhere = http.server.HTTPServer(("127.0.0.1", 0), Elsewhere)

        class First(Elsewhere):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{elsewhere.server_port}/stolen")
                self.end_headers()

        first = http.server.HTTPServer(("127.0.0.1", 0), First)
        for server in (first, elsewhere):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
        real_check = PUBLISH.check_cf_host
        # The first hop is a local server standing in for CurseForge; only that one call is waved through.
        hops = [lambda _url: None]
        with tempfile.TemporaryDirectory() as tmp, \
             mock.patch.object(PUBLISH, "check_cf_host", lambda url: (hops.pop() if hops else real_check)(url)), \
             self.assertRaisesRegex(ValueError, "refusing"):
            PUBLISH.fetch_with_cf_key(f"http://127.0.0.1:{first.server_port}/f.zip", Path(tmp) / "f.zip", "secret")
        self.assertEqual(seen, [])
        # An API call follows no redirect at all, so the key stops at the first answer.
        request = PUBLISH.urllib.request.Request(f"http://127.0.0.1:{first.server_port}/v1/mods/1", headers={"x-api-key": "secret"})
        with self.assertRaisesRegex(PUBLISH.urllib.error.URLError, "refusing to follow a redirect"):
            PUBLISH.urllib.request.build_opener(PUBLISH.NoRedirects).open(request, timeout=5)
        self.assertEqual(seen, [])

    def test_an_api_call_sends_the_key_to_curseforges_api_host_only(self):
        for api in ("https://evil.example/v1", "http://api.curseforge.com/v1", "https://api.curseforge.com.evil.example/v1"):
            with self.subTest(api), mock.patch.object(PUBLISH, "CF_API", api),                  mock.patch.object(PUBLISH.urllib.request.OpenerDirector, "open", side_effect=AssertionError("a request was made")),                  self.assertRaisesRegex(ValueError, "refusing to send the CurseForge key"):
                PUBLISH.cf_get("/mods/1", "secret")


class DownloadsAndLinks(unittest.TestCase):
    def test_a_download_past_the_cap_is_refused_and_a_smaller_one_lands_whole(self):
        out = io.BytesIO()
        with self.assertRaises(ValueError):
            PUBLISH.copy_capped(io.BytesIO(b"x" * 11), out, "https://example/x.zip", cap=10)
        out = io.BytesIO()
        self.assertEqual(PUBLISH.copy_capped(io.BytesIO(b"y" * 10), out, "https://example/y.zip", cap=10), 10)
        self.assertEqual(out.getvalue(), b"y" * 10)

    def test_a_link_under_client_mods_is_not_published(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "data"; public = Path(tmp) / "public"
            folder = data / "client-mods" / "Linked"; folder.mkdir(parents=True)
            (folder / "Scripts").mkdir(); (folder / "Scripts" / "main.lua").write_text("print(1)")
            secret = Path(tmp) / "secret.pem"; secret.write_text("private")
            try:
                (folder / "key.pem").symlink_to(secret)
            except (OSError, NotImplementedError):
                self.skipTest("this account cannot make symlinks")
            with self.assertRaises(ValueError) as caught:
                PUBLISH.resolve_local({"name": "Linked"}, {"type": "local"}, data, public, "Linked")
            self.assertIn("is a link", str(caught.exception))
            self.assertFalse((public / "files" / "Linked.zip").exists())


if __name__ == "__main__": unittest.main()
