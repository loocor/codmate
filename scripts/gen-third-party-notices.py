#!/usr/bin/env python3
import json
import os
import subprocess
import sys


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RESOLVED_PATH = os.path.join(ROOT, "Package.resolved")
OUTPUT_PATH = os.path.join(ROOT, "THIRD-PARTY-NOTICES.md")

LICENSE_FILES = [
    "LICENSE",
    "LICENSE.txt",
    "LICENSE.md",
    "COPYING",
    "COPYING.txt",
    "COPYING.md",
    "LICENCE",
    "LICENCE.txt",
    "LICENCE.md",
]
NOTICE_FILES = ["NOTICE", "NOTICE.txt", "NOTICE.md"]


def run_git(args, cwd):
    try:
        result = subprocess.run(
            ["git"] + args, cwd=cwd, check=True, capture_output=True, text=True
        )
        return result.stdout.strip()
    except Exception:
        return ""


def repo_url_for_path(path):
    url = run_git(["config", "--get", "remote.origin.url"], cwd=path)
    return url if url else None


def read_file(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read().strip()


def pick_first_existing(base_dir, names):
    for name in names:
        candidate = os.path.join(base_dir, name)
        if os.path.isfile(candidate):
            return candidate
    return None


def checkout_dir_for_pin(identity, location):
    candidates = []
    if identity:
        candidates.append(os.path.join(ROOT, ".build", "checkouts", identity))
    if location:
        base = os.path.basename(location.rstrip("/"))
        if base.endswith(".git"):
            base = base[: -len(".git")]
        candidates.append(os.path.join(ROOT, ".build", "checkouts", base))
    for c in candidates:
        if os.path.isdir(c):
            return c
    return None


def version_label(state):
    if not state:
        return "unknown"
    if "version" in state:
        return state["version"]
    if "branch" in state and "revision" in state:
        return f'{state["branch"]}@{state["revision"][:7]}'
    if "revision" in state:
        return state["revision"][:7]
    return "unknown"


def load_pins():
    if not os.path.isfile(RESOLVED_PATH):
        print("ERROR: Package.resolved not found.", file=sys.stderr)
        sys.exit(1)
    with open(RESOLVED_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)
    return data.get("pins", [])


def main():
    pins = load_pins()
    entries = []

    for pin in pins:
        identity = pin.get("identity", "")
        location = pin.get("location", "")
        state = pin.get("state", {})
        entries.append(
            {
                "name": identity,
                "repo": location,
                "version": version_label(state),
                "path": checkout_dir_for_pin(identity, location),
            }
        )

    # Local dependency: SwiftTerm
    swiftterm_path = os.path.join(ROOT, "SwiftTerm")
    if os.path.isdir(swiftterm_path):
        entries.append(
            {
                "name": "SwiftTerm",
                "repo": repo_url_for_path(swiftterm_path) or "https://github.com/migueldeicaza/SwiftTerm",
                "version": run_git(["describe", "--tags", "--abbrev=0"], cwd=swiftterm_path)
                or run_git(["rev-parse", "--short", "HEAD"], cwd=swiftterm_path)
                or "local",
                "path": swiftterm_path,
            }
        )

    # Deduplicate by name (keep first occurrence)
    seen = set()
    unique_entries = []
    for e in entries:
        key = e["name"].lower()
        if key in seen:
            continue
        seen.add(key)
        unique_entries.append(e)

    unique_entries.sort(key=lambda x: x["name"].lower())

    missing = []
    sections = []
    for e in unique_entries:
        name = e["name"] or "unknown"
        repo = e["repo"] or "unknown"
        version = e["version"] or "unknown"
        path = e["path"]

        license_path = None
        notice_path = None
        if path and os.path.isdir(path):
            license_path = pick_first_existing(path, LICENSE_FILES)
            notice_path = pick_first_existing(path, NOTICE_FILES)
        if not license_path:
            missing.append(name)

        header = [f"{name} ({version})", f"Repository: {repo}"]
        if license_path:
            header.append(f"License file: {os.path.basename(license_path)}")
        else:
            header.append("License file: NOT FOUND")

        body = []
        if license_path:
            body.append(read_file(license_path))
        if notice_path:
            body.append("")
            body.append(f"NOTICE ({os.path.basename(notice_path)})")
            body.append(read_file(notice_path))

        sections.append("\n".join(header + [""] + body).strip())

    out = [
        "Third-Party Notices",
        "",
        "This document lists third-party components included in CodMate distributions, along with their licenses and attributions. The original license texts are reproduced or referenced below.",
        "",
        "If you distribute CodMate binaries, keep this file together with `LICENSE`.",
        "",
        "---",
        "",
    ]
    out.append("\n\n---\n\n".join(sections))
    content = "\n".join(out).strip() + "\n"

    if missing:
        print("ERROR: Missing license files for:", ", ".join(sorted(missing)), file=sys.stderr)
        print("Hint: run `swift package resolve` and retry.", file=sys.stderr)
        sys.exit(1)

    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"[ok] Updated {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
