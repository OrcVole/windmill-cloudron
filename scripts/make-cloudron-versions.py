#!/usr/bin/env python3
"""Generate CloudronVersions.json from CloudronManifest.json.

Inlines the manifest, expands the file:// fields (description/changelog/postInstallMessage),
pins dockerImage to the registry digest, and enforces the stricter community-channel schema
(valid contactEmail, non-empty iconUrl, >=1 mediaLinks, bracket-format changelog).

Usage:
  scripts/make-cloudron-versions.py --digest sha256:... [--date 2026-06-27T00:00:00.000Z]
"""
import argparse, json, os, re, sys, datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(p):
    with open(os.path.join(ROOT, p), encoding="utf-8") as f:
        return f.read()


def expand_file_fields(m):
    for key in ("description", "changelog", "postInstallMessage"):
        v = m.get(key)
        if isinstance(v, str) and v.startswith("file://"):
            m[key] = read(v[len("file://"):])
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--digest", required=True, help="registry digest, e.g. sha256:abc...")
    ap.add_argument("--date", help="ISO-8601 UTC; default now")
    ap.add_argument("--out", default="CloudronVersions.json")
    args = ap.parse_args()

    m = json.loads(read("CloudronManifest.json"))
    image_repo = "ghcr.io/orcvole/windmill-cloudron"
    digest = args.digest if args.digest.startswith("sha256:") else "sha256:" + args.digest

    version = m["version"]
    m = expand_file_fields(m)
    m["dockerImage"] = f"{image_repo}@{digest}"
    # icon stays file://logo.png for on-server builds; iconUrl is the store-facing one (kept).

    # Bracket-format changelog required.
    if not re.search(r"(?m)^\[%s\]" % re.escape(version), read("CHANGELOG")):
        sys.exit("CHANGELOG must contain a bracket entry [%s] at line start" % version)

    if not m.get("contactEmail"):
        sys.exit("manifest needs a valid contactEmail")
    if not m.get("iconUrl"):
        sys.exit("manifest needs a non-empty iconUrl")
    if not m.get("mediaLinks"):
        sys.exit("manifest needs >=1 mediaLinks")

    date = args.date or (datetime.datetime.now(datetime.timezone.utc)
                         .strftime("%Y-%m-%dT%H:%M:%S.000Z"))
    ts = int(datetime.datetime.strptime(date, "%Y-%m-%dT%H:%M:%S.000Z")
             .replace(tzinfo=datetime.timezone.utc).timestamp() * 1000)

    out = {
        "stable": True,
        "versions": {
            version: {
                "manifest": m,
                "creationDate": date,
                "ts": ts,
                "publishState": "published",
            }
        },
    }
    with open(os.path.join(ROOT, args.out), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("wrote %s for version %s -> %s@%s" % (args.out, version, image_repo, digest))


if __name__ == "__main__":
    main()
