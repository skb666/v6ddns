"""Cloudflare 客户端与运行入口的离线回归测试。"""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "v6ddns/lib"))
import cloudflare


def script(name):
    loader = importlib.machinery.SourceFileLoader(name, str(ROOT / "v6ddns/bin" / name))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def record(rid="one", name="example.com", rtype="AAAA", content="2001:db8::1", **extra):
    return dict(id=rid, name=name, type=rtype, content=content, **extra)


def reply(result, pages=None, **extra):
    body = dict(success=True, result=result, **extra)
    if pages is not None:
        body["result_info"] = {"total_pages": pages}
    return body


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.client = cloudflare.Client("test-token", "zone-id")
        self.urlopen = mock.patch("cloudflare.urllib.request.urlopen").start()
        self.addCleanup(mock.patch.stopall)

    def respond(self, *bodies):
        responses = []
        for body in bodies:
            response = mock.MagicMock()
            response.__enter__.return_value.status = 200
            response.__enter__.return_value.read.return_value = (
                body if isinstance(body, bytes) else json.dumps(body).encode())
            responses.append(response)
        self.urlopen.side_effect = responses

    def request(self, index=-1):
        return self.urlopen.call_args_list[index].args[0]

    def payload(self, index=-1):
        return json.loads(self.request(index).data)

    def test_exact_query_auth_and_pagination(self):
        first = record()
        second = record("two")
        self.respond(reply([first], 2), reply([second], 2))
        self.assertEqual(self.client.records("example.com", "AAAA"), [first, second])
        for page, call in enumerate(self.urlopen.call_args_list, 1):
            req = call.args[0]
            self.assertEqual(req.get_method(), "GET")
            self.assertEqual(req.get_header("Authorization"), "Bearer test-token")
            self.assertEqual(urllib.parse.urlsplit(req.full_url).path,
                             "/client/v4/zones/zone-id/dns_records")
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(req.full_url).query)
            self.assertEqual(query["name.exact"], ["example.com"])
            self.assertEqual(query["type"], ["AAAA"])
            self.assertEqual(query["page"], [str(page)])
            self.assertEqual(call.kwargs["timeout"], 30)

    def test_create_root_and_subdomain_aaaa_unproxied(self):
        for name in ("example.com", "www.example.com"):
            with self.subTest(name=name):
                self.respond(reply([], 1), reply(record(name=name)))
                self.client.set_aaaa(name, "2001:db8::1")
                self.assertEqual(self.request().get_method(), "POST")
                self.assertEqual(self.payload(), dict(type="AAAA", name=name,
                    content="2001:db8::1", ttl=120, proxied=False))

    def test_patch_only_content_preserves_existing_attributes(self):
        old = record(content="2001:db8::2", ttl=900, proxied=True, comment="keep")
        self.respond(reply([old], 1), reply(record()))
        self.client.set_aaaa("example.com", "2001:db8::1", 120)
        self.assertEqual(self.request().get_method(), "PATCH")
        self.assertEqual(self.payload(), {"content": "2001:db8::1"})
        self.assertTrue(self.request().full_url.endswith("/dns_records/one"))

    def test_unchanged_aaaa_does_not_write(self):
        self.respond(reply([record()], 1))
        self.assertIn("unchanged", self.client.set_aaaa("example.com", "2001:db8::1"))
        self.assertEqual(self.urlopen.call_count, 1)

    def test_duplicate_aaaa_warns_without_deleting(self):
        self.respond(reply([record(), record("two")], 1))
        with self.assertWarnsRegex(UserWarning, "2 AAAA records.*only the first"):
            self.client.set_aaaa("example.com", "2001:db8::1")
        self.assertEqual(self.urlopen.call_count, 1)

    def test_duplicate_aaaa_updates_only_first(self):
        self.respond(reply([record(content="2001:db8::2"), record("two")], 1), reply(record()))
        with self.assertWarns(UserWarning):
            self.client.set_aaaa("example.com", "2001:db8::1")
        self.assertEqual([c.args[0].get_method() for c in self.urlopen.call_args_list],
                         ["GET", "PATCH"])
        self.assertTrue(self.request().full_url.endswith("/dns_records/one"))

    def test_txt_values_are_separate_posts(self):
        name = "_acme-challenge.www.example.com"
        self.respond(reply(record(name=name, rtype="TXT", content="First")),
                     reply(record("two", name, "TXT", "Second")))
        self.client.add_txt(name, "First")
        self.client.add_txt(name, "Second")
        self.assertEqual([c.args[0].get_method() for c in self.urlopen.call_args_list],
                         ["POST", "POST"])
        self.assertEqual(self.payload(0), dict(type="TXT", name=name, content="First", ttl=120))

    def test_cleanup_exact_case_quoted_values_and_id_only_delete(self):
        name = "_acme-challenge.example.com"
        records = [record("a", name, "TXT", "Token"),
                   record("b", name, "TXT", '"Token"'),
                   record("c", name, "TXT", "token"),
                   record("d", name, "TXT", "Other")]
        self.respond(reply(records[:2], 2), reply(records[2:], 2),
                     {"result": {"id": "a"}}, reply({"id": "b"}))
        self.assertEqual(self.client.delete_txt(name, "Token"), ["a", "b"])
        self.assertEqual([c.args[0].get_method() for c in self.urlopen.call_args_list],
                         ["GET", "GET", "DELETE", "DELETE"])
        self.assertNotIn("content.exact", self.request(0).full_url)

    def test_cleanup_requires_nonempty_value(self):
        for value in (None, ""):
            with self.subTest(value=value), self.assertRaises(cloudflare.CloudflareError):
                self.client.delete_txt("_acme-challenge.example.com", value)
        self.urlopen.assert_not_called()

    def test_api_and_malformed_list_errors_are_not_empty_results(self):
        cases = [b"not JSON", [], {"success": False, "errors": [{"code": 10000}]},
                 {"result": [], "result_info": {"total_pages": 1}},
                 reply(None, 1), reply({}, 1), reply([{}], 1),
                 reply([record(content=None)], 1), reply([record(rid="")], 1),
                 reply([record(name="other.example.com")], 1),
                 reply([record(rtype="TXT")], 1), reply([], None),
                 reply([], "2"), reply([], -1), reply([], True)]
        for body in cases:
            with self.subTest(body=body):
                self.respond(body)
                with self.assertRaises(cloudflare.CloudflareError):
                    self.client.records("example.com", "AAAA")

    def test_zero_page_empty_result(self):
        self.respond(reply([], 0))
        self.assertEqual(self.client.records("example.com", "AAAA"), [])

    def test_network_and_http_errors(self):
        for exc in (urllib.error.URLError("offline"), TimeoutError("timeout"),
                    urllib.error.HTTPError("https://example.invalid", 403, "Forbidden", {},
                                           io.BytesIO(b"denied"))):
            with self.subTest(error=type(exc).__name__):
                self.urlopen.side_effect = exc
                with self.assertRaises(cloudflare.CloudflareError):
                    self.client.records("example.com", "AAAA")

    def test_http_json_error_keeps_context_and_redacts_token(self):
        body = {"success": False, "errors": [
            {"code": 10000, "message": "Authentication error for test-token"}]}
        self.urlopen.side_effect = urllib.error.HTTPError(
            "https://example.invalid", 403, "Forbidden", {},
            io.BytesIO(json.dumps(body).encode()))
        with self.assertRaises(cloudflare.CloudflareError) as raised:
            self.client.records("example.com", "AAAA")
        message = str(raised.exception)
        for detail in ("GET", "/zones/zone-id/dns_records?", "HTTP 403", "10000",
                       "Authentication error", "[REDACTED]"):
            self.assertIn(detail, message)
        self.assertNotIn("test-token", message)

    def test_http200_api_error_keeps_code_message_and_redacts_token(self):
        self.respond({"success": False, "errors": [
            {"code": 9109, "message": "Permission denied to edit DNS records: test-token"}]})
        with self.assertRaises(cloudflare.CloudflareError) as raised:
            self.client.records("example.com", "AAAA")
        message = str(raised.exception)
        for detail in ("GET", "/zones/zone-id/dns_records?", "HTTP 200", "9109",
                       "Permission denied to edit DNS records", "[REDACTED]"):
            self.assertIn(detail, message)
        self.assertNotIn("test-token", message)

    def test_http_nonjson_error_is_redacted_before_truncation(self):
        body = "denied test-token " + "x" * 280 + "test-token " + "x" * 1000 + "END"
        self.urlopen.side_effect = urllib.error.HTTPError(
            "https://example.invalid", 502, "Bad Gateway", {}, io.BytesIO(body.encode()))
        with self.assertRaises(cloudflare.CloudflareError) as raised:
            self.client.records("example.com", "AAAA")
        message = str(raised.exception)
        for detail in ("GET", "/zones/zone-id/dns_records?", "HTTP 502", "denied", "[REDACTED]"):
            self.assertIn(detail, message)
        self.assertNotIn("test-token", message)
        self.assertNotIn("END", message)
        self.assertLess(len(message), 500)

    def test_api_failure_without_details_remains_clear(self):
        for body in ({"success": False}, []):
            with self.subTest(body=body):
                self.respond(body)
                with self.assertRaises(cloudflare.CloudflareError) as raised:
                    self.client.records("example.com", "AAAA")
                message = str(raised.exception)
                for detail in ("GET", "/zones/zone-id/dns_records?", "HTTP 200"):
                    self.assertIn(detail, message)
                self.assertRegex(message, "invalid|did not confirm success")

    def test_invalid_create_result_rejected(self):
        for result in ({}, {"id": "one"}, record(content="2001:db8::9"),
                       record(rtype="TXT")):
            with self.subTest(result=result):
                self.respond(reply([], 1), reply(result))
                with self.assertRaises(cloudflare.CloudflareError):
                    self.client.set_aaaa("example.com", "2001:db8::1")

    def test_invalid_update_result_rejected(self):
        self.respond(reply([record(content="2001:db8::2")], 1), reply(record("wrong")))
        with self.assertRaises(cloudflare.CloudflareError):
            self.client.set_aaaa("example.com", "2001:db8::1")

    def test_delete_result_must_confirm_id_and_not_report_failure(self):
        for body in ({"result": {}}, {"result": {"id": "wrong"}},
                     {"success": False, "result": {"id": "one"}},
                     {"success": None, "result": {"id": "one"}}):
            with self.subTest(body=body):
                name = "_acme-challenge.example.com"
                self.respond(reply([record(name=name, rtype="TXT", content="Token")], 1), body)
                with self.assertRaises(cloudflare.CloudflareError):
                    self.client.delete_txt(name, "Token")


class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp/opencode")
        self.addCleanup(self.tmp.cleanup)
        self.envfile = Path(self.tmp.name) / "env"
        self.state = Path(self.tmp.name) / "address"
        self.cfg = dict(V6DDNS_PROVIDER="cloudflare", V6DDNS_DOMAIN="example.com",
                        V6DDNS_TOKEN="test-token", V6DDNS_ZONE_ID="zone-id")
        self.write_config()

    def write_config(self):
        self.envfile.write_text("\n".join(f"{key}={value}" for key, value in self.cfg.items()))

    def ddns(self):
        module = script("v6-ddns")
        module.ENV_FILE = str(self.envfile)
        module.STATE_FILE = str(self.state)
        return module

    def invoke_ddns(self, module, *args):
        with mock.patch.object(sys, "argv", ["v6-ddns", *args]), \
             mock.patch.object(module, "uplink", return_value="eth0"), \
             mock.patch.object(module, "detect", return_value="2001:db8::1"), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            module.main()

    def test_from_env_and_shared_paths(self):
        client = cloudflare.Client.from_env(str(self.envfile))
        self.assertEqual((client.token, client.zone_id), ("test-token", "zone-id"))
        self.assertEqual(cloudflare.STATE_FILE, "/var/lib/v6-ddns/address")
        self.assertEqual(cloudflare.ENV_FILE,
                         os.environ.get("V6DDNS_ENV") or "/etc/v6-ddns/env")

    def test_missing_credentials_rejected(self):
        for key in ("V6DDNS_TOKEN", "V6DDNS_ZONE_ID"):
            with self.subTest(key=key):
                original = self.cfg.pop(key)
                self.write_config()
                with self.assertRaises(cloudflare.CloudflareError):
                    cloudflare.Client.from_env(str(self.envfile))
                with contextlib.redirect_stderr(io.StringIO()) as stderr, self.assertRaises(SystemExit):
                    self.ddns().load_config()
                self.assertIn(f"{key} is not set", stderr.getvalue())
                self.cfg[key] = original

    def test_provider_validation_and_root_subdomain_names(self):
        module = self.ddns()
        cfg = module.load_config()
        self.assertEqual(module.fqdn(cfg), "example.com")
        self.assertEqual(cfg["V6DDNS_TTL"], "120")
        cfg["V6DDNS_HOST"] = "www"
        self.assertEqual(module.fqdn(cfg), "www.example.com")
        for provider in ("alidns", "dnspod", "other"):
            self.cfg["V6DDNS_PROVIDER"] = provider
            self.write_config()
            with self.subTest(provider=provider), contextlib.redirect_stderr(io.StringIO()) as stderr:
                with self.assertRaises(SystemExit):
                    module.load_config()
                self.assertIn(f"unsupported provider {provider!r}", stderr.getvalue())

    def test_success_updates_state(self):
        module = self.ddns()
        with mock.patch.object(cloudflare.Client, "set_aaaa", return_value="created") as update:
            self.invoke_ddns(module)
        update.assert_called_once_with("example.com", "2001:db8::1", 120)
        self.assertEqual(self.state.read_text(), "2001:db8::1\n")

    def test_failure_does_not_update_state(self):
        module = self.ddns()
        for existing in (False, True):
            with self.subTest(existing=existing):
                if existing:
                    self.state.write_text("old\n")
                with mock.patch.object(cloudflare.Client, "set_aaaa",
                                       side_effect=cloudflare.CloudflareError("failed")):
                    with self.assertRaises((SystemExit, cloudflare.CloudflareError)):
                        self.invoke_ddns(module)
                self.assertEqual(self.state.read_text() if existing else self.state.exists(),
                                 "old\n" if existing else False)

    def test_real_client_malformed_response_never_updates_state(self):
        module = self.ddns()
        self.state.write_text("old\n")
        bodies = [b"not JSON", json.dumps(reply([{}], 1)).encode(),
                  json.dumps({"success": False, "result": []}).encode()]
        for body in bodies:
            with self.subTest(body=body), mock.patch("cloudflare.urllib.request.urlopen") as urlopen:
                urlopen.return_value.__enter__.return_value.status = 200
                urlopen.return_value.__enter__.return_value.read.return_value = body
                with self.assertRaises(cloudflare.CloudflareError):
                    self.invoke_ddns(module)
                self.assertEqual(self.state.read_text(), "old\n")

    def test_real_client_success_updates_state(self):
        module = self.ddns()
        with mock.patch("cloudflare.urllib.request.urlopen") as urlopen:
            urlopen.return_value.__enter__.return_value.status = 200
            urlopen.return_value.__enter__.return_value.read.return_value = json.dumps(
                reply([record()], 1)).encode()
            self.invoke_ddns(module)
        self.assertEqual(self.state.read_text(), "2001:db8::1\n")

    def test_diagnostic_api_failures_never_update_state(self):
        module = self.ddns()
        for kind in ("http_json", "api_failure", "http_nonjson"):
            for existing in (False, True):
                with self.subTest(kind=kind, existing=existing), \
                     mock.patch("cloudflare.urllib.request.urlopen") as urlopen:
                    if existing:
                        self.state.write_text("old\n")
                    else:
                        self.state.unlink(missing_ok=True)
                    body = {"success": False, "errors": [
                        {"code": 9109, "message": "Permission denied: test-token"}]}
                    if kind == "api_failure":
                        response = urlopen.return_value.__enter__.return_value
                        response.status = 200
                        response.read.return_value = json.dumps(body).encode()
                    else:
                        raw = json.dumps(body).encode() if kind == "http_json" else b"denied test-token"
                        urlopen.side_effect = urllib.error.HTTPError(
                            "https://example.invalid", 403, "Forbidden", {}, io.BytesIO(raw))
                    with self.assertRaises(cloudflare.CloudflareError) as raised:
                        self.invoke_ddns(module)
                    message = str(raised.exception)
                    self.assertIn("/zones/zone-id/dns_records?", message)
                    self.assertNotIn("test-token", message)
                    self.assertEqual(self.state.read_text() if existing else self.state.exists(),
                                     "old\n" if existing else False)

    def test_dry_run_does_not_call_api_or_update_state(self):
        module = self.ddns()
        self.state.write_text("old\n")
        with mock.patch.object(cloudflare, "Client") as client:
            self.invoke_ddns(module, "--dry-run")
        client.assert_not_called()
        self.assertEqual(self.state.read_text(), "old\n")

    def test_unchanged_state_and_force(self):
        module = self.ddns()
        self.state.write_text("2001:db8::1\n")
        with mock.patch.object(cloudflare.Client, "set_aaaa", return_value="unchanged") as update:
            self.invoke_ddns(module)
            update.assert_not_called()
            self.invoke_ddns(module, "--force")
            update.assert_called_once()

    def hook(self, mode="auth", domain="example.com", validation="Token"):
        module = script("cloudflare-dns01")
        module.ENV_FILE = str(self.envfile)
        env = {"CERTBOT_DOMAIN": domain, "CERTBOT_VALIDATION": validation}
        return module, mock.patch.dict(os.environ, env, clear=True), \
            mock.patch.object(sys, "argv", ["cloudflare-dns01", mode])

    def test_auth_domain_names_and_fixed_wait(self):
        cases = {"example.com": "_acme-challenge.example.com",
                 "www.example.com": "_acme-challenge.www.example.com",
                 "*.example.com": "_acme-challenge.example.com",
                 "*.www.example.com": "_acme-challenge.www.example.com",
                 "WWW.Example.COM.": "_acme-challenge.www.example.com"}
        for domain, name in cases.items():
            with self.subTest(domain=domain):
                module, env, argv = self.hook(domain=domain)
                with env, argv, mock.patch.object(cloudflare.Client, "add_txt") as add, \
                     mock.patch.object(module.time, "sleep") as sleep, \
                     contextlib.redirect_stdout(io.StringIO()):
                    module.main()
                    add.assert_called_once_with(name, "Token")
                    sleep.assert_called_once_with(30)

    def test_cleanup_uses_challenge_value_without_wait(self):
        module, env, argv = self.hook("cleanup", "www.example.com")
        with env, argv, mock.patch.object(cloudflare.Client, "delete_txt", return_value=["one"]) as delete, \
             mock.patch.object(module.time, "sleep") as sleep, \
             contextlib.redirect_stdout(io.StringIO()):
            module.main()
            delete.assert_called_once_with("_acme-challenge.www.example.com", "Token")
            sleep.assert_not_called()

    def test_missing_validation_auth_and_cleanup_refused(self):
        for mode in ("auth", "cleanup"):
            module, env, argv = self.hook(mode, validation="")
            with self.subTest(mode=mode), env, argv, mock.patch.object(cloudflare, "Client") as client:
                with self.assertRaises(SystemExit):
                    module.main()
                client.assert_not_called()

    def test_outside_or_missing_domain_refused_before_api(self):
        for domain in ("", "evil.com", "notexample.com", "example.com.evil.com", "*.*.example.com"):
            module, env, argv = self.hook(domain=domain)
            with self.subTest(domain=domain), env, argv, mock.patch.object(cloudflare, "Client") as client:
                with self.assertRaises(SystemExit):
                    module.main()
                client.assert_not_called()

    def test_failed_auth_does_not_wait(self):
        module, env, argv = self.hook()
        with env, argv, mock.patch.object(cloudflare.Client, "add_txt",
                                         side_effect=cloudflare.CloudflareError("failed")), \
             mock.patch.object(module.time, "sleep") as sleep:
            with self.assertRaises((SystemExit, cloudflare.CloudflareError)):
                module.main()
            sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
