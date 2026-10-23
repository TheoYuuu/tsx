"""Read-only update-service configuration checks; never changes account settings."""
import json
import re
import urllib.request

BYPASS_EXPRESSION = '(http.host eq "updates.uuthings.com" and (starts_with(http.request.uri.path, "/tsx/macos/qa/") or http.request.uri.path eq "/tsx/macos/stable/appcast.xml"))'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_lock(rules):
    active = [rule for rule in rules if rule.get("enabled")]
    if not any(rule.get("prefix") == "tsx/macos/releases/" and
               rule.get("condition", {}).get("type") == "Indefinite" for rule in active):
        raise RuntimeError("Immutable TSX release lock is missing")
    for rule in active:
        prefix = rule.get("prefix", "")
        if any(path.startswith(prefix) or prefix.startswith(path) for path in
               ("tsx/macos/qa/", "tsx/macos/stable/")):
            raise RuntimeError("Bucket lock must not include QA or mutable manifests")


def validate_cache(rules):
    active = [rule for rule in rules if rule.get("enabled", True)]
    normalize = lambda value: re.sub(r"\s+", "", value)
    if not active or not (active[-1].get("action") == "set_cache_settings"
                           and active[-1].get("action_parameters", {}).get("cache") is False
                           and normalize(active[-1].get("expression", "")) == normalize(BYPASS_EXPRESSION)):
        raise RuntimeError("Expected final cache-bypass rule for TSX QA and stable feed is missing")


def audit(settings, token, request=None):
    def get(path):
        if request:
            return request(path)
        req = urllib.request.Request("https://api.cloudflare.com/client/v4" + path,
                                     headers={"Authorization": "Bearer " + token})
        with urllib.request.build_opener(NoRedirect).open(req, timeout=30) as response:
            result = json.load(response)
        if not result.get("success"):
            raise RuntimeError("Cloudflare configuration audit failed")
        return result["result"]
    zone_id = settings["zone_id"]
    if not re.fullmatch(r"[a-f0-9]{32}", zone_id):
        raise ValueError("Invalid Cloudflare zone ID")
    zone = get("/zones/" + zone_id)
    if zone.get("name") != "uuthings.com" or zone.get("status") != "active" or zone.get("account", {}).get("id") != settings["account_id"]:
        raise RuntimeError("Update zone is not active in the expected account")
    bucket = f"/accounts/{settings['account_id']}/r2/buckets/{settings['bucket']}"
    lock = get(bucket + "/lock")
    validate_lock(lock.get("rules", []))
    managed = get(bucket + "/domains/managed")
    if managed.get("enabled"):
        raise RuntimeError("Public r2.dev access must remain disabled")
    domains = get(bucket + "/domains/custom")
    if not any(item.get("domain") == "updates.uuthings.com" and item.get("enabled")
               and item.get("status", {}).get("ownership") == "active"
               and item.get("status", {}).get("ssl") == "active" for item in domains.get("domains", [])):
        raise RuntimeError("R2 update custom domain and TLS are not active")
    ruleset = get(f"/zones/{zone_id}/rulesets/phases/http_request_cache_settings/entrypoint")
    validate_cache(ruleset.get("rules", []))
    security = get(f"/zones/{zone_id}/settings/security_level")
    bots = get(f"/zones/{zone_id}/bot_management")
    if security.get("value") == "under_attack" or bots.get("fight_mode"):
        raise RuntimeError("Update service must not require browser challenges")
    return {"zone_active": True, "custom_domain_tls_active": True, "r2_dev_disabled": True,
            "release_lock": "tsx/macos/releases/", "cache_bypass": BYPASS_EXPRESSION,
            "bot_fight_mode": False, "under_attack_mode": False}
