"""Minimal Alibaba Cloud DNS (alidns) RPC client -- stdlib only.

Shared by v6-ddns, v6-stale-sweep and the certbot DNS-01 hook so the HMAC-SHA1
signing exists in exactly one place.  Credentials come from the KEY=VALUE file
named by ENV_FILE (/etc/v6-ddns/env unless V6DDNS_ENV overrides it).
"""

import base64
import hashlib
import hmac
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://dns.aliyuncs.com/"
VERSION = "2015-01-09"

# Credentials live outside any home directory: certbot's hook and v6-ddns.service
# both run as root, so one root-only file serves both with no identity games.
# V6DDNS_ENV still overrides the location for unusual setups.
ENV_FILE = os.environ.get("V6DDNS_ENV") or "/etc/v6-ddns/env"
# Fixed path, not per-user: the timer and a manual `v6-ddns` run must share one
# state file, or a run under a different account writes state the timer never
# sees.  The unit's StateDirectory= creates this directory for us.
STATE_FILE = "/var/lib/v6-ddns/address"


class AlidnsError(Exception):
    def __init__(self, code, message, action=""):
        super().__init__(f"alidns {action} failed: {code}: {message}".strip())
        self.code = code


def load_env(path):
    cfg = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, val = line.partition("=")
                cfg[key.strip()] = val.strip().strip("'\"")
    return cfg


def sign(params, secret, method="GET"):
    """AliRPC SignatureVersion 1.0.

    Two encoding passes: each key/value is encoded, then the joined string is
    encoded again -- which is why Alibaba echoes the timestamp as %253A
    (':' -> %3A -> %253A).  Verified against the live API.
    """
    enc = lambda s: urllib.parse.quote(str(s), safe="-._~")
    canonical = "&".join(f"{enc(k)}={enc(v)}" for k, v in sorted(params.items()))
    string_to_sign = f"{method}&%2F&{enc(canonical)}"
    mac = hmac.new((secret + "&").encode(), string_to_sign.encode(), hashlib.sha1).digest()
    return base64.b64encode(mac).decode()


class Client:
    def __init__(self, key_id, secret):
        self.key_id, self.secret = key_id, secret

    @classmethod
    def from_env(cls, cfg_path, key="V6DDNS_TOKEN"):
        raw = load_env(cfg_path).get(key, "")
        key_id, _, secret = raw.partition(",")
        if not key_id or not secret:
            raise AlidnsError("NoCredential", f"{key} must be '<AccessKeyId>,<AccessKeySecret>'")
        return cls(key_id, secret)

    def call(self, action, **extra):
        params = {
            "AccessKeyId": self.key_id,
            "Action": action,
            "Format": "JSON",
            "SignatureMethod": "HMAC-SHA1",
            "SignatureNonce": f"{int(time.time() * 1000)}-{self.key_id[-6:]}",
            "SignatureVersion": "1.0",
            "Timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "Version": VERSION,
            **extra,
        }
        params["Signature"] = sign(params, self.secret)
        req = urllib.request.Request(
            API + "?" + urllib.parse.urlencode(params), headers={"User-Agent": "alidns-py/1"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            try:
                body = json.loads(detail)
            except json.JSONDecodeError:
                raise AlidnsError(f"HTTP{exc.code}", detail[:300], action)
            raise AlidnsError(body.get("Code", f"HTTP{exc.code}"),
                              body.get("Message", ""), action)
        except urllib.error.URLError as exc:
            raise AlidnsError("NetworkError", str(exc.reason), action)
        # Some AliDNS failures come back as HTTP 200 with an error body.
        if "Code" in body:
            raise AlidnsError(body["Code"], body.get("Message", ""), action)
        return body

    def records(self, name, rtype):
        """All records of rtype at name.  A trailing dot silently matches nothing,
        so the root zone is addressed as "@.domain" (both forms verified live)."""
        reply = self.call("DescribeSubDomainRecords", SubDomain=name, Type=rtype)
        return (reply.get("DomainRecords") or {}).get("Record") or []

    def set_record(self, domain, rr, rtype, value, ttl=600):
        """Create or update.  AliDNS rejects a no-op update with
        DomainRecordDuplicate, so an unchanged value short-circuits here."""
        found = self.records(f"{rr}.{domain}", rtype)
        common = {"RR": rr, "Type": rtype, "Value": value, "TTL": int(ttl)}
        if found:
            if found[0].get("Value") == value:
                return f"unchanged {rr}.{domain} {rtype} id={found[0]['RecordId']}"
            self.call("UpdateDomainRecord", RecordId=found[0]["RecordId"], **common)
            return f"updated {rr}.{domain} {rtype} {found[0].get('Value')} -> {value}"
        created = self.call("AddDomainRecord", DomainName=domain, **common)
        return f"created {rr}.{domain} {rtype} id={created.get('RecordId')}"

    def delete_matching(self, domain, rr, rtype, value=None):
        """Delete records at rr.domain of rtype.  If value is given, only records
        whose value matches are removed; otherwise every record of that type."""
        gone = []
        for rec in self.records(f"{rr}.{domain}", rtype):
            if value is not None and rec.get("Value") != value:
                continue
            self.call("DeleteDomainRecord", RecordId=rec["RecordId"])
            gone.append(rec["RecordId"])
        return gone
