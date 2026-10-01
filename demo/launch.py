#!/usr/bin/env python3
"""Launch a disposable Zig project using the existing Codex CLI login."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

plugin = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="pair-zig-demo-") as temporary:
    root = Path(temporary)
    project = root / "checkout"
    shutil.copytree(plugin / "demo/checkout", project,
                    ignore=shutil.ignore_patterns(".zig-cache", "zig-out"))
    env = {**os.environ, "PAIR_DEMO_PLUGIN_ROOT": str(plugin)}
    for kind in ("CONFIG", "DATA", "STATE", "CACHE"):
        env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
    env["NVIM_APPNAME"] = "pair-demo"
    result = subprocess.run(
        ["nvim", "-i", "NONE", "-u", str(plugin / "demo/init.lua"), "src/cart.zig"],
        cwd=project, env=env,
    )
    source = (project / "src/cart.zig").read_text()
    report = {"exit_code": result.returncode, "accepted_helper": "fn roundCents(" in source,
              "caller_updated": "return roundCents(amount * (1 - discount));" in source}
    output = os.environ.get("PAIR_DEMO_REPORT")
    if output:
        # The report contains only the public fixture and verification results.
        (Path(output).with_suffix(".zig")).write_text(source)
        (Path(output).with_suffix(".json")).write_text(json.dumps(report, indent=2) + "\n")
    raise SystemExit(result.returncode)
