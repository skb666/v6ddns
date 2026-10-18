#!/usr/bin/env bash
#
# v6-ddns: 一条龙部署脚本
#
# 部署内容：
#   /usr/local/bin/v6-ddns              选址 + 更新 AAAA（root 身份运行）
#   /usr/local/bin/v6-stale-sweep       清理前缀已不可路由的地址（需 root）
#   /usr/local/bin/cloudflare-dns01     certbot DNS-01 hook
#   /usr/local/lib/v6ddns/*.py          共享库
#   /etc/v6-ddns/env                    Cloudflare 凭据（root:root 0600）
#   /etc/systemd/system/v6-*.{service,timer}
#   /etc/nginx/conf.d/DOMAIN.conf       80 跳转 443
#
# 用法：
#   sudo ./v6-ddns-install.sh --domain example.com --zone-id ZONE_ID --token API_TOKEN
#   sudo ./v6-ddns-install.sh --domain example.com --zone-id ZONE_ID --token API_TOKEN --issue-cert
#
# 选项：
#   --domain NAME      域名（必填）
#   --zone-id ID       Cloudflare 控制台中的 Zone ID（也可用 V6DDNS_ZONE_ID）
#   --token TOKEN      Cloudflare API Token（也可用 V6DDNS_TOKEN）；可沿用同域 Cloudflare 配置
#   --host LABEL       记录标签，默认 @（即根域）
#   --issue-cert       部署后申请证书（需已装 certbot + python3-certbot-nginx）
#   --no-nginx         跳过 nginx 配置
#   --dry-run          校验并打印计划，不写盘、不调用 API、不要求 root、不显示 Token
#
set -euo pipefail

BINDIR=/usr/local/bin
LIBDIR=/usr/local/lib/v6ddns
UNITDIR=/etc/systemd/system
CONFDIR=/etc/v6-ddns
ENVFILE=$CONFDIR/env
NGINXDIR=/etc/nginx/conf.d

DOMAIN=""; ZONE_ID=${V6DDNS_ZONE_ID:-}; TOKEN=${V6DDNS_TOKEN:-}
HOST="@"; HOST_SET=0; ISSUE_CERT=0; DO_NGINX=1; DRY_RUN=0

die()  { printf '错误: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
need_value() { [ $# -ge 2 ] && [ -n "$2" ] && [[ $2 != --* ]] || die "$1 需要参数"; }

valid_name() {
  local label
  local -a labels
  [ ${#1} -le 253 ] && [[ $1 =~ ^[a-zA-Z0-9.-]+$ && $1 != .* && $1 != *. && $1 != *..* ]] || return 1
  IFS=. read -r -a labels <<< "$1"
  [ ${#labels[@]} -gt 0 ] || return 1
  for label in "${labels[@]}"; do
    [ ${#label} -le 63 ] && [[ $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
  done
}

trim() {
  REPLY=${1#"${1%%[![:space:]]*}"}
  REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
}

while [ $# -gt 0 ]; do
  case $1 in
    --domain)      need_value "$@"; DOMAIN=$2; shift 2 ;;
    --zone-id)     need_value "$@"; ZONE_ID=$2; shift 2 ;;
    --token)       need_value "$@"; TOKEN=$2; shift 2 ;;
    --host)        need_value "$@"; HOST=$2; HOST_SET=1; shift 2 ;;
    --issue-cert)  ISSUE_CERT=1; shift ;;
    --no-nginx)    DO_NGINX=0; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "未知参数，请使用 --help" ;;
  esac
done

[ -n "$DOMAIN" ] || die "必须指定 --domain"
valid_name "$DOMAIN" || die "--domain 格式无效"
DOMAIN=${DOMAIN,,}

# 配置只按数据读取，不 source，避免把凭据文件中的内容当命令执行。
REUSE=0
OLD_EXTRA=()
if [ -f "$ENVFILE" ]; then
  OLD_PROVIDER=""; OLD_DOMAIN=""; OLD_HOST="@"; OLD_ZONE=""; OLD_TOKEN=""
  while IFS= read -r line || [ -n "$line" ]; do
    original=$line
    trim "$line"; line=$REPLY
    if [[ $line == \#* || $line != *=* ]]; then
      OLD_EXTRA+=("$original")
      continue
    fi
    trim "${line%%=*}"; key=$REPLY
    trim "${line#*=}"; value=$REPLY
    if [[ $value == \"*\" || $value == \'*\' ]]; then
      value=${value:1:${#value}-2}
    fi
    case $key in
      V6DDNS_PROVIDER) OLD_PROVIDER=$value ;;
      V6DDNS_DOMAIN) OLD_DOMAIN=$value ;;
      V6DDNS_HOST) OLD_HOST=$value ;;
      V6DDNS_ZONE_ID) OLD_ZONE=$value ;;
      V6DDNS_TOKEN) OLD_TOKEN=$value ;;
      *) OLD_EXTRA+=("$original") ;;
    esac
  done < "$ENVFILE"
  if [ "$OLD_PROVIDER" = cloudflare ] && [ "${OLD_DOMAIN,,}" = "$DOMAIN" ]; then
    if [ "$HOST_SET" = 1 ]; then
      [ "${HOST,,}" = "${OLD_HOST,,}" ] || die "显式 --host 与现有配置不匹配"
    else
      HOST=$OLD_HOST
    fi
    ZONE_ID=${ZONE_ID:-$OLD_ZONE}
    TOKEN=${TOKEN:-$OLD_TOKEN}
    REUSE=1
  else
    [ -n "$ZONE_ID" ] && [ -n "$TOKEN" ] || die "现有配置为旧平台或其他 domain；请显式提供全新 --zone-id 和 --token"
  fi
fi
[ -n "$ZONE_ID" ] || die "必须指定 --zone-id 或 V6DDNS_ZONE_ID（或沿用同域 Cloudflare 配置）"
[[ $ZONE_ID =~ ^[a-fA-F0-9]{32}$ ]] || die "--zone-id 必须为 32 位十六进制 Zone ID"
[ -n "$TOKEN" ] || die "必须指定 --token 或 V6DDNS_TOKEN（或沿用同域 Cloudflare 配置）"
[[ $TOKEN =~ ^[a-zA-Z0-9_-]+$ ]] || die "--token 必须为 Cloudflare API Token，不能使用旧平台 AK,SK"
if [ "$HOST" != @ ]; then
  valid_name "$HOST" || die "--host 格式无效"
  [ ${#HOST} -le $((252 - ${#DOMAIN})) ] || die "--host 与 domain 组合过长"
fi
HOST=${HOST,,}
RENEWAL_FILE="/etc/letsencrypt/renewal/$DOMAIN.conf"

check_lineage() {
  python3 - "$RENEWAL_FILE" "/etc/letsencrypt/live/$DOMAIN" "$DO_NGINX" "$BINDIR/cloudflare-dns01" "$1" <<'PY'
import configparser
from pathlib import Path
import re
import sys

path, live, nginx, hook, saved = sys.argv[1:]
try:
    text = Path(path).read_text()
    # 预检只在内存忽略脚本自有重复键；实际清理在 Certbot 读取前完成。
    text = re.sub(r"^[ \t]*renew_hook[ \t]*=[ \t]*systemctl reload nginx[ \t]*$\n?", "", text, flags=re.M)
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read_string("[lineage]\n" + text)
    for key, filename in (("fullchain", "fullchain.pem"), ("privkey", "privkey.pem")):
        if cfg.get("lineage", key, fallback="") != f"{live}/{filename}":
            raise ValueError("同名 renewal 的证书路径不匹配；请核对 --cert-name 和实际 lineage，不猜测 -0001")
    params = cfg["renewalparams"]
    if nginx == "0" and params.get("installer", "").lower() == "nginx":
        raise ValueError("现有 lineage 的 installer=nginx；--no-nginx 不会移除旧 installer，请先用 Certbot 明确处理该配置")
    if saved == "saved":
        if (params.get("authenticator") != "manual"
                or params.get("pref_challs", "").strip(" ,") not in ("dns", "dns-01")
                or params.get("manual_auth_hook") != f"{hook} auth"
                or params.get("manual_cleanup_hook") != f"{hook} cleanup"):
            raise ValueError("Cloudflare manual/DNS-01 auth/cleanup 未正确持久化")
except (OSError, ValueError, KeyError, configparser.Error) as exc:
    sys.exit(f"错误: renewal 配置校验失败: {exc}")
PY
}

if [ "$DRY_RUN" = 1 ]; then
  step "DRY-RUN：仅校验并展示计划，不实际写入"
  NAME=$DOMAIN; [ "$HOST" = @ ] || NAME=$HOST.$DOMAIN
  info "Cloudflare: $NAME AAAA；Zone ID: $ZONE_ID；Token: 已提供（隐藏）"
  info "凭据: $ENVFILE (root:root 0600)；状态: /var/lib/v6-ddns/address"
  info "程序: $BINDIR/v6-ddns、$BINDIR/v6-stale-sweep、$BINDIR/cloudflare-dns01"
  info "共享库: $LIBDIR/cloudflare.py、$LIBDIR/ipv6state.py；启用两个 systemd timer"
  [ "$REUSE" = 0 ] || info "沿用同域 Cloudflare 配置"
  [ "$DO_NGINX" = 0 ] || info "配置 nginx vhost: $NGINXDIR/$DOMAIN.conf"
  if [ "$ISSUE_CERT" = 1 ]; then
    info "certbot DNS-01: cloudflare-dns01 auth / cleanup；无人值守续期"
    [ "$DO_NGINX" = 0 ] || info "申请成功后检查并 reload nginx；保存限域 deploy hook，保留自定义 renew_hook"
  fi
  exit 0
fi

[ "$(id -u)" = 0 ] || die "请用 sudo 运行"

step "前置检查"
for c in ip python3 systemctl; do
  command -v $c >/dev/null || die "缺少命令: $c"
  info "$c ✓"
done
if [ "$ISSUE_CERT" = 1 ]; then
  command -v certbot >/dev/null || die "缺少命令: certbot"
  [ "$DO_NGINX" = 0 ] || command -v nginx >/dev/null || die "缺少命令: nginx"
  CERTBOT_VERSION=$(certbot --version 2>&1) || die "无法检查 Certbot 版本"
  if [[ $CERTBOT_VERSION =~ certbot[[:space:]]+([0-9]+)\.([0-9]+) ]]; then
    [ "${BASH_REMATCH[1]}" -gt 2 ] || { [ "${BASH_REMATCH[1]}" -eq 2 ] && [ "${BASH_REMATCH[2]}" -ge 3 ]; } || die "需要 Certbot >= 2.3"
  else
    die "无法识别 Certbot 版本；需要 >= 2.3"
  fi
  certbot help reconfigure >/dev/null 2>&1 || die "Certbot 不支持 reconfigure；需要 >= 2.3"
  if [ -f "$RENEWAL_FILE" ]; then
    check_lineage existing
  elif [ -e "/etc/letsencrypt/live/$DOMAIN" ]; then
    die "存在同名 live 目录但缺少 renewal；请先核对实际 lineage"
  fi
fi
if [ "$DO_NGINX" = 1 ]; then
  for file in options-ssl-nginx.conf ssl-dhparams.pem; do
    [ -s "/etc/letsencrypt/$file" ] || die "缺少 nginx TLS 配套文件 /etc/letsencrypt/$file；请按 README 从本机匹配版本 Certbot 包补齐，或使用 --no-nginx"
  done
fi

step "凭据 $ENVFILE"
install -d -m700 -o root -g root "$CONFDIR"
umask 077
if [ "$REUSE" = 1 ] && [ "$ZONE_ID" = "$OLD_ZONE" ] && [ "$TOKEN" = "$OLD_TOKEN" ]; then
  info "沿用现有 $ENVFILE"
else
  cat > "$ENVFILE" <<EOF
# Cloudflare 凭据，安装为 $ENVFILE，root:root 0600；不要提交到 git。
V6DDNS_PROVIDER=cloudflare
V6DDNS_ZONE_ID=$ZONE_ID
V6DDNS_DOMAIN=$DOMAIN
V6DDNS_HOST=$HOST
V6DDNS_TOKEN=$TOKEN
EOF
  if [ "$REUSE" = 1 ] && [ ${#OLD_EXTRA[@]} -gt 0 ]; then
    printf '%s\n' "${OLD_EXTRA[@]}" >> "$ENVFILE"
  fi
fi
chown root:root "$ENVFILE"; chmod 600 "$ENVFILE"
info "已写入 $ENVFILE (root:root 0600)"
umask 022

step "安装程序文件"
install -d -m755 "$LIBDIR" "$BINDIR" "$UNITDIR"
[ "$DO_NGINX" = 1 ] && install -d -m755 "$NGINXDIR"

	install -m644 /dev/stdin "$LIBDIR/cloudflare.py" <<'__V6DDNS_CLOUDFLARE_PY__'
"""供 DDNS 与 certbot DNS-01 共用的 Cloudflare 客户端，仅使用标准库。"""

import ipaddress
import json
import os
import urllib.error
import urllib.parse
import urllib.request
import warnings

API = "https://api.cloudflare.com/client/v4"
ENV_FILE = os.environ.get("V6DDNS_ENV") or "/etc/v6-ddns/env"
STATE_FILE = "/var/lib/v6-ddns/address"


class CloudflareError(Exception):
    pass


def load_env(path):
    cfg = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                cfg[key.strip()] = value.strip().strip("'\"")
    return cfg


def _txt_value(value):
    return value[1:-1] if len(value) >= 2 and value[0] == value[-1] == '"' else value


class Client:
    def __init__(self, token, zone_id):
        if not token or not zone_id:
            raise CloudflareError("V6DDNS_TOKEN and V6DDNS_ZONE_ID are required")
        self.token, self.zone_id = token, zone_id
        self.path = f"/zones/{urllib.parse.quote(zone_id, safe='')}/dns_records"

    @classmethod
    def from_env(cls, path):
        cfg = load_env(path)
        return cls(cfg.get("V6DDNS_TOKEN"), cfg.get("V6DDNS_ZONE_ID"))

    def _call(self, method, path, payload=None):
        status = None

        def error(detail):
            target = f"{method} {path}" + (f" -> HTTP {status}" if status is not None else "")
            # 先脱敏再截断，避免截断后的 token 前缀泄漏。
            detail = str(detail).replace(self.token, "[REDACTED]")
            if len(detail) > 300:
                detail = detail[:300] + "..."
            return CloudflareError(f"{target}: {detail}".replace(self.token, "[REDACTED]"))

        req = urllib.request.Request(
            API + path, method=method,
            data=json.dumps(payload).encode() if payload is not None else None,
            headers={"Authorization": f"Bearer {self.token}",
                     "Content-Type": "application/json", "User-Agent": "v6-ddns/1"})
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                status = response.status
                raw = response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            status = exc.code
            raw = exc.read().decode("utf-8", "replace")
        except OSError as exc:
            raise error(f"request failed: {exc}") from exc
        try:
            body = json.loads(raw)
        except ValueError as exc:
            raise error(f"non-JSON response: {raw}") from exc
        if not isinstance(body, dict):
            raise error("invalid response")
        if status >= 400 or body.get("errors"):
            errors = body.get("errors")
            details = "; ".join(f"{item.get('code', '')}: {item.get('message', '')}"
                                for item in errors if isinstance(item, dict)) if isinstance(errors, list) else ""
            raise error(details or "invalid or unsuccessful response")
        # DELETE 的官方响应允许省略 success，但仍须由调用方核对 result.id。
        if body.get("success") is not True and not (method == "DELETE" and "success" not in body):
            raise error("Cloudflare did not confirm success")
        return body

    @staticmethod
    def _record(rec, name, rtype):
        if (not isinstance(rec, dict) or not isinstance(rec.get("id"), str) or not rec["id"]
                or not isinstance(rec.get("name"), str)
                or rec["name"].rstrip(".").lower() != name.rstrip(".").lower()
                or rec.get("type") != rtype or not isinstance(rec.get("content"), str)):
            raise CloudflareError("invalid DNS record result")
        if rtype == "AAAA":
            try:
                ipaddress.IPv6Address(rec["content"])
            except ValueError as exc:
                raise CloudflareError("invalid AAAA content") from exc
        return rec

    def records(self, name, rtype):
        found = []
        page = 1
        while True:
            query = urllib.parse.urlencode({"name.exact": name, "type": rtype,
                                            "page": page, "per_page": 100})
            body = self._call("GET", self.path + "?" + query)
            records = body.get("result")
            info = body.get("result_info")
            pages = info.get("total_pages") if isinstance(info, dict) else None
            if (not isinstance(records, list) or type(pages) is not int or pages < 0
                    or (pages < page and not (page == 1 and pages == 0 and not records))):
                raise CloudflareError("invalid DNS record list or pagination")
            found.extend(self._record(rec, name, rtype) for rec in records)
            if page >= pages:
                return found
            page += 1

    def _write(self, method, name, rtype, value, payload, rid=None):
        path = self.path + ("/" + urllib.parse.quote(rid, safe="") if rid else "")
        rec = self._record(self._call(method, path, payload).get("result"), name, rtype)
        matches = (ipaddress.IPv6Address(rec["content"]) == ipaddress.IPv6Address(value)
                   if rtype == "AAAA" else _txt_value(rec["content"]) == _txt_value(value))
        if not matches or (rid is not None and rec["id"] != rid):
            raise CloudflareError("DNS write result does not match the requested record")
        return rec["id"]

    def set_aaaa(self, name, address, ttl=120):
        found = self.records(name, "AAAA")
        if len(found) > 1:
            warnings.warn(f"{len(found)} AAAA records exist for {name}; only the first is "
                          "kept in sync -- delete the others or clients will round-robin "
                          "onto a stale address", stacklevel=2)
        if found:
            rec = found[0]
            if ipaddress.IPv6Address(rec["content"]) == ipaddress.IPv6Address(address):
                return f"unchanged AAAA {name} (id {rec['id']})"
            rid = self._write("PATCH", name, "AAAA", address, {"content": address}, rec["id"])
            return f"updated AAAA {name} (id {rid})"
        rid = self._write("POST", name, "AAAA", address,
                          {"type": "AAAA", "name": name, "content": address,
                           "ttl": int(ttl), "proxied": False})
        return f"created AAAA {name} (id {rid})"

    def add_txt(self, name, value, ttl=120):
        if not value:
            raise CloudflareError("TXT validation value is required")
        return self._write("POST", name, "TXT", value,
                           {"type": "TXT", "name": name, "content": value, "ttl": int(ttl)})

    def delete_txt(self, name, value):
        if not value:
            raise CloudflareError("TXT validation value is required for cleanup")
        gone = []
        for rec in self.records(name, "TXT"):
            # content.exact 不区分大小写，挑战值必须在本地严格匹配。
            if _txt_value(rec["content"]) != _txt_value(value):
                continue
            body = self._call("DELETE", self.path + "/" + urllib.parse.quote(rec["id"], safe=""))
            result = body.get("result")
            if not isinstance(result, dict) or result.get("id") != rec["id"]:
                raise CloudflareError("DELETE result does not confirm the requested record id")
            gone.append(rec["id"])
        return gone
__V6DDNS_CLOUDFLARE_PY__
	info "已安装 $LIBDIR/cloudflare.py (mode 644)"
	install -m644 /dev/stdin "$LIBDIR/ipv6state.py" <<'__V6DDNS_IPV6STATE_PY__'
"""Read the host's real IPv6 state and tell stale addresses apart from live ones.

Shared by v6-ddns (so it never publishes a dead address) and v6-stale-sweep
(so the kernel stops preferring one for outbound traffic).

The key fact: an address is only reachable while the router still advertises the
prefix it sits in.  A router reboot that lands on a new /64 stops advertising the
old one but does NOT send a deprecating RA, so the old address stays "valid" in
the kernel until valid_lft expires -- measured at ~70 hours on this line.  A
device can therefore hold a syntactically perfect, completely dead address.
"""

import ipaddress
import json
import subprocess


def _run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def onlink_prefixes(iface):
    """Prefixes the router currently advertises as on-link (RA-derived routes).

    Empty when no RA has arrived yet -- callers must treat that as "cannot tell"
    rather than "everything is stale".
    """
    data = json.loads(_run(["ip", "-j", "-6", "route", "show", "dev", iface, "proto", "ra"]))
    nets = set()
    for route in data:
        dst = route.get("dst")
        if not dst or dst == "default":
            continue
        try:
            nets.add(ipaddress.ip_network(dst, strict=False))
        except ValueError:
            continue
    return nets


def global_addresses(iface):
    """Global addresses on iface, with the flags iproute2 reports."""
    data = json.loads(_run(["ip", "-j", "-6", "addr", "show", "dev", iface, "scope", "global"]))
    return [a for link in data for a in link.get("addr_info", []) if a.get("local")]


def _is_stale(addr, prefixes):
    """True when addr's /64 sits in no advertised prefix."""
    net = ipaddress.ip_network(f"{addr['local']}/64", strict=False)
    return not any(net.subnet_of(p) for p in prefixes)


def stale_addresses(iface):
    """Live-looking global addresses the router no longer routes.

    Returns [] when there is no on-link prefix to compare against: a router that
    is merely rebooting briefly advertises nothing, and treating that as "all
    addresses are dead" would be exactly backwards.
    """
    prefixes = onlink_prefixes(iface)
    if not prefixes:
        return []
    return [a for a in global_addresses(iface) if _is_stale(a, prefixes)]


def publishable(iface):
    """The address v6-ddns should publish, or None.

    Prefers the host-derived stable-privacy address (RFC 7217) over the SLAAC
    EUI-64 one (mngtmpaddr) so the record does not leak the MAC, and drops
    temporary (rotates), deprecated, and stale (unrouted) candidates.
    """
    prefixes = onlink_prefixes(iface)
    candidates = [
        a for a in global_addresses(iface)
        if not a.get("temporary") and not a.get("deprecated")
        and (not prefixes or not _is_stale(a, prefixes))
    ]
    if not candidates:
        return None
    candidates.sort(key=lambda a: a.get("mngtmpaddr", False))
    return candidates[0]["local"]
__V6DDNS_IPV6STATE_PY__
	info "已安装 $LIBDIR/ipv6state.py (mode 644)"
	install -m755 /dev/stdin "$BINDIR/v6-ddns" <<'__V6DDNS_V6DDNS__'
#!/usr/bin/env python3
"""Publish this host's stable-privacy IPv6 as a DNS AAAA record.

Detects the uplink's global IPv6 and updates DNS only when the address actually
changed.  stdlib only -- no packages to install.

Credentials: /etc/v6-ddns/env  (root:root 0600)
State:       /var/lib/v6-ddns/address

  v6-ddns            update DNS if the address changed
  v6-ddns --dry-run  report what would happen; touches no DNS and no state
  v6-ddns --print    print the detected address and exit
  v6-ddns --force    update even if the address is unchanged
"""

import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "lib", "v6ddns"))
import cloudflare
import ipv6state

ENV_FILE = cloudflare.ENV_FILE
STATE_FILE = cloudflare.STATE_FILE


def die(msg):
    print(f"v6-ddns: {msg}", file=sys.stderr)
    sys.exit(1)


def log(msg):
    print(f"v6-ddns: {msg}", file=sys.stderr)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def load_config():
    try:
        cfg = cloudflare.load_env(ENV_FILE)
    except FileNotFoundError:
        die(f"missing {ENV_FILE}")
    for key in ("V6DDNS_PROVIDER", "V6DDNS_DOMAIN", "V6DDNS_TOKEN", "V6DDNS_ZONE_ID"):
        if not cfg.get(key):
            die(f"{key} is not set in {ENV_FILE}")
    if not cfg.get("V6DDNS_HOST"):
        cfg["V6DDNS_HOST"] = "@"
    provider = cfg["V6DDNS_PROVIDER"].lower()
    if provider != "cloudflare":
        die(f"unsupported provider {provider!r}; use cloudflare")
    cfg["V6DDNS_PROVIDER"] = provider
    cfg.setdefault("V6DDNS_TTL", "120")
    return cfg


def uplink(iface):
    """Interface holding the default IPv6 route (or the configured one)."""
    if iface:
        return iface
    for line in run(["ip", "-6", "route", "show", "default"]).splitlines():
        fields = line.split()
        if "dev" in fields:
            return fields[fields.index("dev") + 1]
    die("no default IPv6 route")


def detect(iface):
    """The address to publish.

    Ignores temporary (RFC 4941, rotates) and deprecated addresses, plus any
    address whose prefix the router no longer advertises -- a router reboot on a
    new /64 leaves the old address looking valid for up to valid_lft (~70h here)
    while being completely unroutable, and it would otherwise win the tie-break
    simply by being older.
    """
    addr = ipv6state.publishable(iface)
    if not addr:
        die(f"no usable global IPv6 on {iface}")
    return addr


def fqdn(cfg):
    host = cfg["V6DDNS_HOST"]
    if host in ("@", ""):
        return cfg["V6DDNS_DOMAIN"]
    return f"{host}.{cfg['V6DDNS_DOMAIN']}"


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--print", dest="show", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--iface", default=os.environ.get("V6DDNS_IFACE", ""))
    args = ap.parse_args()

    iface = uplink(args.iface)
    if args.show:
        print(detect(iface))
        return

    cfg = load_config()
    addr = detect(iface)
    previous = None
    try:
        previous = open(STATE_FILE).read().strip()
    except FileNotFoundError:
        pass

    if previous == addr and not args.force:
        log(f"{addr} unchanged")
        return
    if args.dry_run:
        print(f"would publish {fqdn(cfg)} AAAA {addr}"
              f"{'' if previous is None else f' (was {previous})'} via {cfg['V6DDNS_PROVIDER']}")
        return

    client = cloudflare.Client.from_env(ENV_FILE)
    outcome = client.set_aaaa(fqdn(cfg), addr, int(cfg["V6DDNS_TTL"]))
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w") as fh:
        fh.write(addr + "\n")
    log(outcome)


if __name__ == "__main__":
    try:
        main()
    except (cloudflare.CloudflareError, OSError, ValueError) as exc:
        die(str(exc))
__V6DDNS_V6DDNS__
	info "已安装 $BINDIR/v6-ddns (mode 755)"
	install -m755 /dev/stdin "$BINDIR/cloudflare-dns01" <<'__V6DDNS_CLOUDFLARE_HOOK__'
#!/usr/bin/env python3
"""certbot DNS-01 hook：auth 添加挑战，cleanup 仅删除对应挑战值。"""

import os
import sys
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "lib", "v6ddns"))
import cloudflare

ENV_FILE = cloudflare.ENV_FILE


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "auth"
    if mode not in ("auth", "cleanup"):
        sys.exit(f"cloudflare-dns01: unknown mode {mode!r} (expected auth or cleanup)")
    domain = os.environ.get("CERTBOT_DOMAIN", "").lower().rstrip(".")
    validation = os.environ.get("CERTBOT_VALIDATION", "")
    if not domain or not validation:
        sys.exit("cloudflare-dns01: CERTBOT_DOMAIN and CERTBOT_VALIDATION are required")
    if domain.startswith("*."):
        domain = domain[2:]
    cfg = cloudflare.load_env(ENV_FILE)
    zone = cfg.get("V6DDNS_DOMAIN", "").lower().rstrip(".")
    if (not zone or "*" in domain
            or not (domain == zone or domain.endswith("." + zone))):
        sys.exit("cloudflare-dns01: CERTBOT_DOMAIN is outside V6DDNS_DOMAIN")
    name = f"_acme-challenge.{domain}"
    client = cloudflare.Client.from_env(ENV_FILE)
    if mode == "auth":
        rid = client.add_txt(name, validation)
        print(f"created TXT {name} (id {rid})")
        time.sleep(30)
    else:
        gone = client.delete_txt(name, validation)
        print(f"removed {len(gone)} TXT record(s)" if gone else "nothing to remove")


if __name__ == "__main__":
    try:
        main()
    except (cloudflare.CloudflareError, OSError) as exc:
        sys.exit(f"cloudflare-dns01: {exc}")
__V6DDNS_CLOUDFLARE_HOOK__
	info "已安装 $BINDIR/cloudflare-dns01 (mode 755)"
	install -m755 /dev/stdin "$BINDIR/v6-stale-sweep" <<'__V6DDNS_V6STALE__'
#!/usr/bin/env python3
"""Delete global IPv6 addresses whose prefix the router no longer advertises.

Needs root, since it mutates the address list.  Safe by construction:

  * Never acts when there is no on-link prefix to compare against -- a router
    mid-reboot briefly advertises nothing, and calling every address dead at
    that moment would be exactly backwards.
  * Only considers scope global addresses on the uplink interface.
  * Touches nothing when the current prefix is the only one present, which is
    the normal case, so this is a no-op on virtually every run.

Usage: v6-stale-sweep [interface]   (default: interface owning the default v6 route)
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "lib", "v6ddns"))
import ipv6state  # noqa: E402


def log(msg):
    print(f"v6-stale-sweep: {msg}", file=sys.stderr)


def default_iface():
    for line in ipv6state._run(["ip", "-6", "route", "show", "default"]).splitlines():
        fields = line.split()
        if "dev" in fields:
            return fields[fields.index("dev") + 1]
    return None


def main():
    if os.geteuid() != 0:
        sys.exit("v6-stale-sweep: must run as root")
    iface = sys.argv[1] if len(sys.argv) > 1 else default_iface()
    if not iface:
        sys.exit("v6-stale-sweep: no interface given and no default IPv6 route")

    prefixes = ipv6state.onlink_prefixes(iface)
    if not prefixes:
        log(f"{iface}: no on-link prefix advertised right now, leaving addresses alone")
        return

    stale = [a for a in ipv6state.global_addresses(iface) if ipv6state._is_stale(a, prefixes)]
    if not stale:
        log(f"{iface}: clean, advertised {', '.join(sorted(map(str, prefixes)))}")
        return

    for addr in stale:
        spec = f"{addr['local']}/{addr.get('prefixlen', 64)}"
        try:
            subprocess.run(["ip", "-6", "addr", "del", spec, "dev", iface],
                           capture_output=True, text=True, check=True)
            log(f"deleted {spec} (its prefix is no longer advertised)")
        except subprocess.CalledProcessError as exc:
            log(f"could not delete {spec}: {exc.stderr.strip() or exc}")


if __name__ == "__main__":
    main()
__V6DDNS_V6STALE__
	info "已安装 $BINDIR/v6-stale-sweep (mode 755)"
	install -m644 /dev/stdin "$UNITDIR/v6-ddns.service" <<'__V6DDNS_DDNS_SERVICE__'
[Unit]
Description=Publish this host's stable-privacy IPv6 as a DNS AAAA record
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/v6-ddns
StateDirectory=v6-ddns
ProtectHome=true
NoNewPrivileges=true
PrivateTmp=true
__V6DDNS_DDNS_SERVICE__
	info "已安装 $UNITDIR/v6-ddns.service (mode 644)"
	install -m644 /dev/stdin "$UNITDIR/v6-ddns.timer" <<'__V6DDNS_DDNS_TIMER__'
[Unit]
Description=Check for IPv6 address changes every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=v6-ddns.service

[Install]
WantedBy=timers.target
__V6DDNS_DDNS_TIMER__
	info "已安装 $UNITDIR/v6-ddns.timer (mode 644)"
	install -m644 /dev/stdin "$UNITDIR/v6-stale-sweep.service" <<'__V6DDNS_SWEEP_SERVICE__'
[Unit]
Description=Drop global IPv6 addresses whose prefix the router stopped advertising
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# Needs root: it mutates the kernel address list.
ExecStart=/usr/local/bin/v6-stale-sweep
# A failure here is worth seeing in the journal but must never block v6-ddns.
SuccessExitStatus=0
__V6DDNS_SWEEP_SERVICE__
	info "已安装 $UNITDIR/v6-stale-sweep.service (mode 644)"
	install -m644 /dev/stdin "$UNITDIR/v6-stale-sweep.timer" <<'__V6DDNS_SWEEP_TIMER__'
[Unit]
Description=Check for unrouted IPv6 addresses every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=v6-stale-sweep.service

[Install]
WantedBy=timers.target
__V6DDNS_SWEEP_TIMER__
	info "已安装 $UNITDIR/v6-stale-sweep.timer (mode 644)"
if [ "$DO_NGINX" = 1 ]; then
	install -m644 /dev/stdin "$NGINXDIR/$DOMAIN.conf" <<'__V6DDNS_NGINX_VHOST__'
# example.com -- install as /etc/nginx/conf.d/example.com.conf
#
# Deliberately does NOT declare default_server, so it coexists with the Debian
# default site in sites-enabled: requests for example.com match by server_name here,
# anything else keeps falling through to the stock catch-all vhost.
#
# Port 80 only redirects; the certificate is issued via DNS-01, so nothing has
# to stay reachable there for renewal.  Cert paths come from:
#   sudo certbot certonly --manual --preferred-challenges dns ...
# Install order matters -- the certificate must exist before nginx loads this.

server {
	listen 80;
	listen [::]:80;
	server_name example.com;

	# The certificate is issued via DNS-01, so nothing here needs to be reachable
	# for renewal -- port 80 is free to redirect unconditionally.  $request_uri
	# carries the query string across; $host keeps the hostname, dropping :80.
	return 301 https://$host$request_uri;
}

server {
	listen 443 ssl;
	listen [::]:443 ssl;
	server_name example.com;

	root /var/www/html;
	index index.html index.htm index.nginx-debian.html;

	ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

	# Session/cipher/protocol settings come from this file -- declaring them here
	# too is a hard "directive is duplicate" error at nginx -t.
	include /etc/letsencrypt/options-ssl-nginx.conf;
	ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

	location / {
		try_files $uri $uri/ =404;
	}
}
__V6DDNS_NGINX_VHOST__
	sed -i "s|example\.com|$DOMAIN|g" "$NGINXDIR/$DOMAIN.conf"
	info "已安装 nginx vhost (mode 644)"
fi

step "启用 systemd 服务"
systemctl daemon-reload
systemctl enable --now v6-ddns.timer v6-stale-sweep.timer
systemctl list-timers 'v6-*' --no-pager || true
info "证书有效期 $(cat /etc/letsencrypt/live/$DOMAIN/fullchain.pem 2>/dev/null | openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2)"

if [ "$ISSUE_CERT" = 1 ]; then
  step "申请证书 (DNS-01)"
  RENEWAL_FILE="/etc/letsencrypt/renewal/$DOMAIN.conf"
  DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/v6-ddns-nginx-$DOMAIN"
  # Certbot 读取前修复旧脚本产生的重复键，仅删除脚本自己的确切命令。
  if [ -f "$RENEWAL_FILE" ]; then
    sed -i '/^[[:space:]]*renew_hook[[:space:]]*=[[:space:]]*systemctl reload nginx[[:space:]]*$/d' "$RENEWAL_FILE"
  fi
  if [ "$DO_NGINX" = 0 ]; then
    rm -f "$DEPLOY_HOOK"
  fi
  if [ -f "$RENEWAL_FILE" ]; then
    certbot reconfigure --cert-name "$DOMAIN" --manual --preferred-challenges dns \
      --manual-auth-hook "$BINDIR/cloudflare-dns01 auth" \
      --manual-cleanup-hook "$BINDIR/cloudflare-dns01 cleanup" --non-interactive
  else
    certbot certonly --cert-name "$DOMAIN" --manual --preferred-challenges dns \
      --non-interactive \
    --manual-auth-hook    "$BINDIR/cloudflare-dns01 auth" \
    --manual-cleanup-hook "$BINDIR/cloudflare-dns01 cleanup" \
    -d "$DOMAIN"
  fi
  check_lineage saved
  if [ "$DO_NGINX" = 1 ]; then
    install -d -m755 "/etc/letsencrypt/renewal-hooks/deploy"
    cat > "$DEPLOY_HOOK" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# 仅刷新本安装域名对应的 lineage，不影响其他证书。
[ "\${RENEWED_LINEAGE:-}" = "/etc/letsencrypt/live/$DOMAIN" ] || exit 0
nginx -t
systemctl reload nginx
EOF
    chmod 755 "$DEPLOY_HOOK"
    nginx -t
    systemctl reload nginx
  fi
fi

step "完成"
step "验证"
"$BINDIR/v6-ddns" --print | sed 's/^/  当前地址: /'
systemctl --no-pager --full status v6-ddns.service 2>/dev/null | head -3 || true
printf '\n剩余手动步骤:\n'
printf '  1. 路由器 ACL: 放行 TCP 80 443（以及你需要的其他端口）\n'
printf '  2. 手机蜂窝网络测试: curl -6 -I https://%s/\n' "$DOMAIN"
printf '  3. 建议: sudo cupsctl --listen-ip-address=127.0.0.1  （631 不该公网可达）\n'
