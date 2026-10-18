"""安装器离线契约；所有目标路径都替换为临时目录，不接触真实凭据。"""

from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "v6-ddns-install.sh"
ZONE = "a" * 32
TOKEN = "offline-test-token-DO-NOT-PRINT"


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="v6ddns-install-", dir="/tmp/opencode")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.commands = self.base / "commands"
        self.commands.mkdir()
        self.log = self.base / "calls"
        self.script = self.base / "install.sh"
        text = INSTALLER.read_text()
        for old, new in {
            "/usr/local/bin": self.base / "bin",
            "/usr/local/lib/v6ddns": self.base / "lib",
            "/etc/systemd/system": self.base / "units",
            "/etc/v6-ddns": self.base / "config",
            "/etc/nginx/conf.d": self.base / "nginx",
            "/etc/letsencrypt": self.base / "letsencrypt",
        }.items():
            text = text.replace(old, str(new))
        self.script.write_text(text)
        self.envfile = self.base / "config/env"
        self.env = {"PATH": f"{self.commands}:/usr/bin:/bin", "LC_ALL": "C.UTF-8"}
        self.fake("id", "printf '1000\\n'")
        for name in ("install", "chown", "chmod", "systemctl", "certbot", "nginx", "ip"):
            self.fake(name, "exit 97")

    def fake(self, name, body):
        path = self.commands / name
        path.write_text(f'#!/bin/bash\nprintf "%s\\n" "{name} $*" >> "{self.log}"\n{body}\n')
        path.chmod(0o755)

    def run_install(self, *args, root=False):
        if root:
            self.fake("id", "printf '0\\n'")
        return subprocess.run(["bash", str(self.script), *args], env=self.env,
                              capture_output=True, text=True)

    def credentials(self, **overrides):
        cfg = dict(V6DDNS_PROVIDER="cloudflare", V6DDNS_DOMAIN="example.com",
                   V6DDNS_HOST="home", V6DDNS_ZONE_ID=ZONE, V6DDNS_TOKEN=TOKEN)
        cfg.update(overrides)
        self.envfile.parent.mkdir(exist_ok=True)
        self.envfile.write_text("".join(f"{key}={value}\n" for key, value in cfg.items()))

    def assert_no_effects(self, result, existing=False):
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        self.assertFalse(self.log.exists(), self.log.read_text() if self.log.exists() else "")
        self.assertEqual(self.envfile.exists(), existing)
        for name in ("bin", "lib", "units", "nginx", "letsencrypt"):
            self.assertFalse((self.base / name).exists())

    def test_help_documents_cloudflare_zone(self):
        result = self.run_install("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--zone-id", result.stdout)
        self.assertIn("Cloudflare", result.stdout)
        self.assert_no_effects(result)

    def test_dry_run_nonroot_no_commands_no_secret(self):
        result = self.run_install("--domain", "example.com", "--zone-id", ZONE,
                                  "--token", TOKEN, "--issue-cert", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cloudflare-dns01", result.stdout)
        self.assertIn("DRY-RUN", result.stdout)
        self.assert_no_effects(result)

    def test_environment_credentials(self):
        self.env.update(V6DDNS_ZONE_ID=ZONE, V6DDNS_TOKEN=TOKEN)
        result = self.run_install("--domain", "example.com", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_effects(result)

    def test_cli_credentials_override_environment(self):
        self.env.update(V6DDNS_ZONE_ID="invalid", V6DDNS_TOKEN="AK,SK")
        result = self.run_install("--domain", "example.com", "--zone-id", ZONE,
                                  "--token", TOKEN, "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_effects(result)

    def test_unknown_argument_does_not_echo_secret(self):
        result = self.run_install(TOKEN)
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_effects(result)

    def test_missing_and_unsafe_arguments_fail_before_writes(self):
        cases = [([], "--domain"), (["--domain", "example.com"], "--zone-id"),
                 (["--domain", "example.com", "--zone-id", ZONE], "--token"),
                 (["--domain", "../escape", "--zone-id", ZONE, "--token", TOKEN], "domain"),
                 (["--domain", "example.com", "--zone-id", "invalid", "--token", TOKEN], "zone"),
                 (["--domain", "example.com", "--zone-id", ZONE, "--token", "AK,SK"], "token"),
                 (["--domain", "example.com", "--host", "bad\nname", "--zone-id", ZONE,
                   "--token", TOKEN], "host"),
                 (["--token"], "--token"),
                 (["--zone-id", "--dry-run"], "--zone-id")]
        for args, expected in cases:
            for mode in ((), ("--dry-run",)):
                with self.subTest(args=args, mode=mode):
                    result = self.run_install(*args, *mode)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, result.stderr.lower())
                    self.assert_no_effects(result)

    def test_existing_cloudflare_config_reused_without_changes(self):
        self.credentials()
        before = self.envfile.read_bytes()
        result = self.run_install("--domain", "example.com", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("home.example.com", result.stdout)
        self.assertEqual(self.envfile.read_bytes(), before)
        self.assert_no_effects(result, existing=True)

    def test_invalid_reuse_rejected(self):
        cases = [dict(V6DDNS_PROVIDER="alidns", V6DDNS_TOKEN="AK,SK"),
                 dict(V6DDNS_DOMAIN="other.example"), dict(V6DDNS_ZONE_ID=""),
                 dict(V6DDNS_TOKEN=""), dict(V6DDNS_TOKEN="AK,SK")]
        for overrides in cases:
            with self.subTest(overrides=overrides):
                self.credentials(**overrides)
                result = self.run_install("--domain", "example.com", "--dry-run")
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_effects(result, existing=True)

    def test_explicit_host_mismatch_rejected(self):
        self.credentials()
        result = self.run_install("--domain", "example.com", "--host", "@", "--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_effects(result, existing=True)

    def test_existing_env_is_data_not_shell(self):
        self.credentials(V6DDNS_TOKEN=f"$(touch {self.base}/injected)")
        result = self.run_install("--domain", "example.com", "--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / "injected").exists())
        self.assert_no_effects(result, existing=True)

    def mock_install(self):
        # 只让 install 在临时目录落盘；运行程序替换为空命令，绝不执行内嵌运行链路。
        self.fake("install", '''
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-g) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
if [[ "$*" == *"/dev/stdin"* ]]; then
  target="${@: -1}"
  /usr/bin/install "$@"
  if [[ "$target" == "''' + str(self.base / "bin") + '''/"* ]]; then
    printf '#!/bin/bash\\nexit 0\\n' > "$target"
  fi
else
  /usr/bin/install "$@"
fi''')
        self.fake("chmod", 'exec /usr/bin/chmod "$@"')
        for name in ("chown", "systemctl", "nginx", "ip"):
            self.fake(name, "exit 0")
        tls = self.base / "letsencrypt"
        tls.mkdir(exist_ok=True)
        for name in ("options-ssl-nginx.conf", "ssl-dhparams.pem"):
            (tls / name).write_text("离线 TLS 文件\n")
        self.fake_certbot()

    def fake_certbot(self, *, save=True, version="2.9.0", fail=False, reconfigure=True):
        # certonly 保留已有未到期配置；只有 reconfigure 才保存新参数。
        self.fake("certbot", f'''exec /usr/bin/python3 - "$@" <<'PY'
import configparser
from pathlib import Path
import sys
args = sys.argv[1:]
if args == ["--version"]:
    print("certbot {version}")
    sys.exit(0)
if args == ["help", "reconfigure"]:
    sys.exit(0 if {reconfigure!r} else 1)
name = args[args.index("--cert-name") + 1] if "--cert-name" in args else "example.com"
path = Path({str(self.base / "letsencrypt/renewal")!r}) / (name + ".conf")
cfg = configparser.ConfigParser(interpolation=None)
if path.exists():
    cfg.read_string("[lineage]\\n" + path.read_text())
    if args[0] == "certonly":
        sys.exit(0)
else:
    assert args[0] == "certonly", args
    live = Path({str(self.base / "letsencrypt/live")!r}) / name
    cfg["lineage"] = {{"fullchain": str(live / "fullchain.pem"), "privkey": str(live / "privkey.pem")}}
    cfg["renewalparams"] = {{}}
if {fail!r}:
    sys.exit(45)
if {save!r}:
    cfg["renewalparams"].update({{"authenticator": "manual", "pref_challs": "dns-01",
        "manual_auth_hook": args[args.index("--manual-auth-hook") + 1],
        "manual_cleanup_hook": args[args.index("--manual-cleanup-hook") + 1]}})
    path.parent.mkdir(parents=True, exist_ok=True)
    import io
    output = io.StringIO()
    cfg.write(output)
    path.write_text(output.getvalue().removeprefix("[lineage]\\n"))
PY''')

    def renewal(self, extra=""):
        path = self.base / "letsencrypt/renewal/example.com.conf"
        path.parent.mkdir(parents=True, exist_ok=True)
        live = self.base / "letsencrypt/live/example.com"
        path.write_text(f"fullchain = {live}/fullchain.pem\nprivkey = {live}/privkey.pem\n"
                        "[renewalparams]\n" + extra)
        return path

    def test_mock_install_config_hooks_and_repeat(self):
        self.mock_install()
        renewal = self.renewal("renew_hook = systemctl reload nginx\n" * 2)
        args = ("--domain", "example.com", "--zone-id", ZONE, "--token", TOKEN, "--issue-cert")
        for _ in range(2):
            result = self.run_install(*args, root=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(TOKEN, result.stdout + result.stderr)
        cfg = self.envfile.read_text()
        self.assertIn("V6DDNS_PROVIDER=cloudflare\n", cfg)
        self.assertIn(f"V6DDNS_ZONE_ID={ZONE}\n", cfg)
        self.assertIn(f"V6DDNS_TOKEN={TOKEN}\n", cfg)
        self.assertEqual(self.envfile.stat().st_mode & 0o777, 0o600)
        with self.envfile.open("a") as fh:
            fh.write("# 保留原配置的附加设置\nV6DDNS_TTL=300\n")
        before = self.envfile.read_bytes()
        result = self.run_install("--domain", "example.com", "--no-nginx", root=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.envfile.read_bytes(), before)
        calls = self.log.read_text()
        self.assertIn("chown root:root", calls)
        self.assertIn("cloudflare-dns01 auth", calls)
        self.assertIn("cloudflare-dns01 cleanup", calls)
        self.assertIn("--non-interactive", calls)
        self.assertIn("systemctl reload nginx", calls)
        self.assertEqual(renewal.read_text().count("renew_hook ="), 0)
        deploy = self.base / "letsencrypt/renewal-hooks/deploy/v6-ddns-nginx-example.com"
        self.assertTrue(deploy.exists())
        self.assertTrue(deploy.stat().st_mode & 0o111)
        self.log.unlink()
        result = self.run_install(*args, "--no-nginx", root=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("reload nginx", self.log.read_text())
        self.assertNotIn("renew_hook", renewal.read_text())
        self.assertFalse(deploy.exists())
        result = self.run_install("--domain", "home.example.net", "--zone-id", ZONE,
                                  "--token", TOKEN, root=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        vhost = (self.base / "nginx/home.example.net.conf").read_text()
        self.assertIn("server_name home.example.net;", vhost)
        self.assertIn("/live/home.example.net/fullchain.pem", vhost)
        self.assertNotIn("example.com", vhost)

    def test_reinstall_and_token_rotation_preserve_host_and_extra_config(self):
        self.mock_install()
        for args in (("--zone-id", ZONE, "--token", TOKEN),
                     ("--token", "rotated-token"),
                     ("--zone-id", "b" * 32, "--token", TOKEN)):
            with self.subTest(args=args):
                self.credentials()
                with self.envfile.open("a") as fh:
                    fh.write("# 用户附加配置\nV6DDNS_TTL=300\nV6DDNS_IFACE=enp7s0\n")
                result = self.run_install("--domain", "example.com", *args, "--no-nginx", root=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                cfg = self.envfile.read_text()
                self.assertIn("V6DDNS_HOST=home\n", cfg)
                self.assertIn("V6DDNS_TTL=300\n", cfg)
                self.assertIn("V6DDNS_IFACE=enp7s0\n", cfg)
                self.assertIn("# 用户附加配置\n", cfg)
                self.assertIn(f"V6DDNS_TOKEN={args[-1]}\n", cfg)
                expected_zone = args[1] if args[0] == "--zone-id" else ZONE
                self.assertIn(f"V6DDNS_ZONE_ID={expected_zone}\n", cfg)

    def test_full_credentials_still_reject_host_conflict(self):
        self.credentials()
        result = self.run_install("--domain", "example.com", "--zone-id", ZONE,
                                  "--token", TOKEN, "--host", "@", "--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_effects(result, existing=True)

    def test_old_or_other_domain_requires_both_new_credentials(self):
        self.mock_install()
        for old in (dict(V6DDNS_PROVIDER="alidns", V6DDNS_TOKEN="AK,SK"),
                    dict(V6DDNS_DOMAIN="other.example")):
            with self.subTest(old=old):
                self.credentials(**old)
                for args in (("--token", TOKEN), ("--zone-id", ZONE)):
                    result = self.run_install("--domain", "example.com", *args, "--dry-run")
                    self.assertNotEqual(result.returncode, 0)
                result = self.run_install("--domain", "example.com", "--zone-id", ZONE,
                                          "--token", TOKEN, "--no-nginx", root=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("V6DDNS_PROVIDER=cloudflare\n", self.envfile.read_text())
                self.assertIn("V6DDNS_HOST=@\n", self.envfile.read_text())

    def test_custom_renew_hook_preserved_and_deploy_scoped(self):
        self.mock_install()
        custom = "renew_hook = /usr/local/bin/deploy-my-service\n"
        renewal = self.renewal(custom + "renew_hook = systemctl reload nginx\n" * 2)
        args = ("--domain", "example.com", "--zone-id", ZONE, "--token", TOKEN, "--issue-cert")
        for _ in range(2):
            result = self.run_install(*args, root=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(custom, renewal.read_text())
            self.assertEqual(renewal.read_text().count("renew_hook ="), 1)
        deploy = self.base / "letsencrypt/renewal-hooks/deploy/v6-ddns-nginx-example.com"
        self.assertTrue(deploy.exists())
        self.log.unlink()
        env = dict(self.env, RENEWED_LINEAGE=str(self.base / "letsencrypt/live/other.example"))
        result = subprocess.run(["bash", str(deploy)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())
        env["RENEWED_LINEAGE"] = str(self.base / "letsencrypt/live/example.com")
        result = subprocess.run(["bash", str(deploy)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("systemctl reload nginx", self.log.read_text())
        self.log.unlink()
        result = self.run_install(*args, "--no-nginx", root=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(custom, renewal.read_text())
        self.assertEqual(renewal.read_text().count("renew_hook ="), 1)
        self.assertFalse(deploy.exists())
        self.assertNotIn("nginx -t", self.log.read_text())
        self.assertNotIn("reload nginx", self.log.read_text())

    def test_nginx_check_and_reload_failures_abort(self):
        self.mock_install()
        self.renewal()
        args = ("--domain", "example.com", "--zone-id", ZONE, "--token", TOKEN, "--issue-cert")
        self.fake("nginx", "exit 42")
        result = self.run_install(*args, root=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("剩余手动步骤", result.stdout)
        self.assertNotIn("==> 完成", result.stdout)
        self.assertNotIn("systemctl reload nginx", self.log.read_text())
        self.fake("nginx", "exit 0")
        self.fake("systemctl", 'if [ "$1" = reload ]; then exit 43; fi')
        result = self.run_install(*args, root=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("剩余手动步骤", result.stdout)
        self.assertNotIn("==> 完成", result.stdout)
        result = self.run_install(*args, "--no-nginx", root=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_existing_lineage_reconfigure_persists_and_failure_stops(self):
        self.mock_install()
        renewal = self.renewal("installer = nginx\nauthenticator = manual\nmanual_auth_hook = /old/alidns auth\n"
                               "manual_cleanup_hook = /old/alidns cleanup\n")
        args = ("--domain", "example.com", "--zone-id", ZONE, "--token", TOKEN, "--issue-cert")
        result = self.run_install(*args, root=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = renewal.read_text()
        self.assertIn(f"manual_auth_hook = {self.base}/bin/cloudflare-dns01 auth", saved)
        self.assertIn(f"manual_cleanup_hook = {self.base}/bin/cloudflare-dns01 cleanup", saved)
        self.assertIn("authenticator = manual", saved)
        self.assertIn("installer = nginx", saved)
        self.assertIn("pref_challs = dns-01", saved)
        calls = self.log.read_text()
        self.assertIn("certbot reconfigure --cert-name example.com", calls)
        self.assertNotIn("--force-renewal", calls)
        self.assertNotIn("--staging", calls)
        reconfigure_call = next(line for line in calls.splitlines() if line.startswith("certbot reconfigure "))
        self.assertNotIn(" -d ", reconfigure_call)
        self.fake_certbot(save=False)
        self.renewal("manual_auth_hook = /old/alidns auth\n")
        result = self.run_install(*args, root=True)
        self.assertNotEqual(result.returncode, 0)
        self.fake_certbot(fail=True)
        result = self.run_install(*args, root=True)
        self.assertNotEqual(result.returncode, 0)

    def test_first_certificate_persists_named_lineage(self):
        self.mock_install()
        result = self.run_install("--domain", "example.com", "--zone-id", ZONE,
                                  "--token", TOKEN, "--issue-cert", root=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = (self.base / "letsencrypt/renewal/example.com.conf").read_text()
        self.assertIn("manual_auth_hook =", saved)
        self.assertIn("pref_challs = dns-01", saved)
        self.assertIn("--cert-name example.com", self.log.read_text())

    def test_tls_missing_preflight_and_no_nginx_exemption(self):
        self.mock_install()
        for file in (self.base / "letsencrypt").iterdir():
            file.unlink()
        args = ("--domain", "example.com", "--zone-id", ZONE, "--token", TOKEN, "--issue-cert")
        result = self.run_install(*args, root=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TLS", result.stderr)
        self.assertFalse(self.envfile.exists())
        self.assertFalse((self.base / "nginx").exists())
        self.assertNotIn("install ", self.log.read_text())
        result = self.run_install(*args, "--no-nginx", root=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("nginx -t", self.log.read_text())

    def test_old_certbot_and_mismatched_lineage_rejected_before_writes(self):
        self.mock_install()
        args = ("--domain", "example.com", "--zone-id", ZONE, "--token", TOKEN, "--issue-cert")
        self.fake_certbot(version="2.2.0")
        result = self.run_install(*args, root=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.envfile.exists())
        self.fake_certbot()
        self.fake_certbot(reconfigure=False)
        result = self.run_install(*args, root=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.envfile.exists())
        self.fake_certbot()
        renewal = self.renewal()
        renewal.write_text(renewal.read_text().replace("/live/example.com/", "/live/example.com-0001/"))
        result = self.run_install(*args, root=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.envfile.exists())
        self.renewal("installer = nginx\n")
        result = self.run_install(*args, "--no-nginx", root=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installer", result.stderr)
        self.assertFalse(self.envfile.exists())


class EmbeddedTests(unittest.TestCase):
    def test_all_embedded_sources_match(self):
        text = INSTALLER.read_text()
        sources = {
            "CLOUDFLARE_PY": "lib/cloudflare.py", "IPV6STATE_PY": "lib/ipv6state.py",
            "V6DDNS": "bin/v6-ddns", "CLOUDFLARE_HOOK": "bin/cloudflare-dns01",
            "V6STALE": "bin/v6-stale-sweep", "DDNS_SERVICE": "systemd/v6-ddns.service",
            "DDNS_TIMER": "systemd/v6-ddns.timer", "SWEEP_SERVICE": "systemd/v6-stale-sweep.service",
            "SWEEP_TIMER": "systemd/v6-stale-sweep.timer", "NGINX_VHOST": "nginx/example.com.conf",
        }
        self.assertEqual(set(re.findall(r"<<'__V6DDNS_(\w+)__'", text)), set(sources))
        for marker, source in sources.items():
            with self.subTest(source=source):
                delimiter = f"__V6DDNS_{marker}__"
                match = re.search(r"<<'" + delimiter + r"'\n(.*?)^" + delimiter + r"$", text,
                                  re.MULTILINE | re.DOTALL)
                self.assertIsNotNone(match, f"缺少内嵌 marker: {delimiter}")
                path = ROOT / "v6ddns" / source
                self.assertTrue(path.exists(), f"运行源码依赖尚未就绪: {source}")
                self.assertEqual(match.group(1).encode(), path.read_bytes(), source)

    def test_embedded_python_syntax(self):
        text = INSTALLER.read_text()
        for match in re.finditer(r"<<'(__V6DDNS_\w+__)'\n(.*?)^\1$", text,
                                 re.MULTILINE | re.DOTALL):
            source = match.group(2)
            if source.startswith(('"""', "#!/usr/bin/env python3")):
                compile(source, match.group(1), "exec")

    def test_bash_syntax(self):
        subprocess.run(["bash", "-n", str(INSTALLER)], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
