"""Verify shared-container claims against actual profiles and signing teams."""
from pathlib import Path
import plistlib
import re
import subprocess


def group_authorized(group, *, platform, team, entitlements):
    if not isinstance(group, str) or not group or "*" in group:
        return False
    # Apple permits this separate, unprovisioned namespace only on macOS.
    if platform == "mac" and re.fullmatch(r"[A-Z0-9]{10}", team or "") and group.startswith(team + "."):
        return len(group) > len(team) + 1
    if not group.startswith("group."):
        return False
    allowed = entitlements.get("com.apple.security.application-groups", [])
    if not isinstance(allowed, list):
        return False
    return any(isinstance(value, str) and (value == group or
               (value.endswith("*") and value.count("*") == 1 and group.startswith(value[:-1]))) for value in allowed)


def verify_app_group_products(app, platform):
    app = Path(app)
    content = app / "Contents" if platform == "mac" else app
    containers = [app] + sorted((content / "PlugIns").glob("*.appex"))
    expected = None
    result = []
    for bundle in containers:
        contents = bundle / "Contents" if platform == "mac" else bundle
        info = plistlib.loads((contents / "Info.plist").read_bytes())
        raw = subprocess.check_output(["codesign", "-d", "--entitlements", ":-", str(bundle)], stderr=subprocess.DEVNULL)
        claims = plistlib.loads(raw)
        signature = subprocess.run(["codesign", "-dv", str(bundle)], capture_output=True, text=True, check=True).stderr
        team = next((line.split("=", 1)[1] for line in signature.splitlines() if line.startswith("TeamIdentifier=")), None)
        if not re.fullmatch(r"[A-Z0-9]{10}", team or ""):
            raise ValueError("A real signing team is required for app-group authorization")
        groups = claims.get("com.apple.security.application-groups")
        if not isinstance(groups, list) or not groups or any(not isinstance(g, str) for g in groups) or len(set(groups)) != len(groups):
            raise ValueError("Missing or invalid shared-container claims for " + info["CFBundleIdentifier"])
        if expected is None:
            expected = (team, set(groups))
        elif (team, set(groups)) != expected:
            raise ValueError("App, widget and share extension must use the same team and groups")
        path = contents / ("embedded.provisionprofile" if platform == "mac" else "embedded.mobileprovision")
        profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(path)], stderr=subprocess.DEVNULL)) if path.exists() else {}
        if profile and profile.get("TeamIdentifier") != [team]:
            raise ValueError("Shared-container profile belongs to a different team")
        if any(not group_authorized(g, platform=platform, team=team, entitlements=profile.get("Entitlements", {})) for g in groups):
            raise ValueError("Provisioning profile does not authorize the shared app group for " + info["CFBundleIdentifier"] + "; refresh automatic profiles with REGISTER_APP_GROUPS=YES")
        result.append({"bundle": info["CFBundleIdentifier"], "groups": groups, "team": team,
                       "authorization": "profile" if all(g.startswith("group.") for g in groups) else "macOS-team-namespace"})
    return {"verified": True, "bundles": result}
