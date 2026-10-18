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
