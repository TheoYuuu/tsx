#!/usr/bin/env python3
"""Run fixed public samples through the production Ollama provider.

Requires an already running loopback service and an explicitly chosen model.
Never installs models, discovers accounts, or reads application preferences.
"""

import argparse
import ast
from datetime import datetime, timezone
import json
import pathlib
import platform
import re
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]


def endpoint(value):
    match = re.fullmatch(r"http://(?:127\.0\.0\.1|\[::1\])(?::([0-9]{1,5}))?/v1", value)
    if not match or (match[1] and not 1 <= int(match[1]) <= 65535):
        raise argparse.ArgumentTypeError("Use an HTTP 127.0.0.1 or [::1] URL ending exactly in /v1.")
    return value


def model(value):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}", value):
        raise argparse.ArgumentTypeError("Provide one explicit model name without spaces or options.")
    return value


def production_sources():
    # Reuse the network probe's literal build manifest without importing or
    # executing its server. Fail clearly if that manifest changes shape.
    tree = ast.parse((ROOT / "Tools/QA/remote-translation-network.py").read_text())
    manifests = [
        ast.literal_eval(node.value)
        for node in ast.walk(tree)
        if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == "sources" for target in node.targets)
    ]
    if len(manifests) != 1 or manifests[0][0] != "Tools/QA/RemoteTranslationNetworkProbe.swift":
        raise RuntimeError("The network probe build manifest changed; review the local probe dependencies.")
    return ["Tools/QA/LocalModelTranslationProbe.swift", *manifests[0][1:]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("endpoint", type=endpoint)
    parser.add_argument("model", type=model)
    args = parser.parse_args()
    output_root = ROOT / ".build/QA/LocalModelTranslation"
    output_root.mkdir(parents=True, exist_ok=True)
    output = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=output_root))
    executable = output / "translation-probe"
    print(f"Evidence directory: {output}", flush=True)
    with (output / "build.log").open("w") as log:
        try:
            subprocess.run([
                "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                "-strict-concurrency=complete", "-warnings-as-errors", "-target",
                f"{platform.machine()}-apple-macos15.0", "-O", *production_sources(),
                "-o", str(executable),
            ], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            print("Build failed or exceeded 90 seconds. Inspect build.log.")
            return 1
    timed_out = False
    with (output / "translations.jsonl").open("w") as records, (output / "stderr.log").open("w") as errors:
        try:
            result = subprocess.run(
                [str(executable), args.endpoint, args.model], cwd=ROOT,
                stdout=records, stderr=errors, timeout=450,
            )
            return_code = result.returncode
        except subprocess.TimeoutExpired:
            # subprocess.run kills and waits for its own probe on timeout.
            timed_out, return_code = True, 124
    lines = (output / "translations.jsonl").read_text().splitlines()
    try:
        records = [json.loads(line) for line in lines]
    except json.JSONDecodeError:
        records, return_code = [], 1
    completed = sum(record.get("outcome") == "completed" for record in records)
    passed = return_code == 0 and len(records) == completed == 7
    report = {
        "checkedAt": datetime.now(timezone.utc).isoformat(),
        "scope": "Production Ollama provider with seven constructed samples; quality requires separate review.",
        "endpoint": args.endpoint, "model": args.model,
        "records": len(records), "completed": completed,
        "protocolCompleted": passed, "qualityAssessment": "not_assessed",
        "probeExitCode": return_code, "totalTimeout": timed_out,
    }
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"Completed {completed}/7; quality has not been assessed. See translations.jsonl and report.json.")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
