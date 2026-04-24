"""
Direct Cloudflare API client used by integration tests to seed/verify state.

This is NOT a mock of the script — it is a parallel client that talks to the
real Cloudflare API so that integration tests can pre-populate records,
inspect results, and clean up. Stdlib-only (urllib + json).
"""

import json
import urllib.error
import urllib.request

CF_API_BASE = "https://api.cloudflare.com/client/v4"


def _request(method, path, token, payload=None):
    url = CF_API_BASE + path
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8")
        doc = json.loads(body)
        raise RuntimeError("Cloudflare API error: {}".format(doc))
    return json.loads(body)


def list_a_records(token, zone_id, hostname):
    doc = _request(
        "GET",
        "/zones/{}/dns_records?type=A&name={}".format(zone_id, hostname),
        token,
    )
    return doc.get("result") or []


def create_a_record(token, zone_id, hostname, content, ttl=60):
    doc = _request(
        "POST",
        "/zones/{}/dns_records".format(zone_id),
        token,
        {"type": "A", "name": hostname, "content": content, "ttl": ttl},
    )
    return doc.get("result") or {}


def delete_record(token, zone_id, record_id):
    _request(
        "DELETE",
        "/zones/{}/dns_records/{}".format(zone_id, record_id),
        token,
    )


def delete_all_a_records(token, zone_id, hostname):
    for rec in list_a_records(token, zone_id, hostname):
        delete_record(token, zone_id, rec["id"])
