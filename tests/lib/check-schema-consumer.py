#!/usr/bin/env python3
"""Consume only CLI output and documented encoding; never import host internals."""

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def main():
    cli = [sys.argv[2], sys.argv[1]]
    prefix = "JAILBOX_CONFIG_"
    environment = {k: v for k, v in os.environ.items() if not k.startswith(prefix)}
    with tempfile.TemporaryDirectory(prefix="jailbox-schema-consumer.") as directory:
        root = Path(directory).resolve()
        project = root / "project"
        project.mkdir(mode=0o755)
        project.chmod(0o755)
        environment["XDG_STATE_HOME"] = str(root / "state")
        # No Containerfile: supplying DEV_IMAGE must change validation's result.
        # File policy must not influence these machine-interface calls.
        (project / "jailbox.conf").write_text("not valid configuration\n")
        paths = ["first policy", "second,policy"]
        for name in paths:
            path = project / name
            path.write_text("protected\n")
            path.chmod(0o644)

        def invoke(command, overrides):
            return subprocess.run(
                cli + [command], cwd=project, env={**environment, **overrides},
                capture_output=True, timeout=20,
            )

        result = invoke("config-schema", {})
        assert result.returncode == 0 and not result.stderr, "schema discovery failed"
        assert result.stdout.endswith(b"\n"), "unterminated schema"
        schema = {}
        arrays_started = False
        for record in result.stdout[:-1].split(b"\n"):
            match = re.fullmatch(rb"([A-Z][A-Z0-9_]*)\t(scalar|array)", record)
            assert match, f"malformed schema record: {record!r}"
            key, kind = (part.decode("ascii") for part in match.groups())
            assert key not in schema, f"duplicate key: {key}"
            assert not (arrays_started and kind == "scalar"), "scalar after arrays"
            arrays_started |= kind == "array"
            schema[key] = kind

        def encode(configuration):
            encoded = {}
            for key, value in configuration.items():
                assert key in schema, f"missing required consumer key: {key}"
                name = prefix + key
                if schema[key] == "scalar":
                    assert isinstance(value, str), f"expected array declaration: {key}"
                    encoded[name] = value
                else:
                    assert isinstance(value, list), f"expected scalar declaration: {key}"
                    if not value:
                        encoded[name] = ""
                    for index, member in enumerate(value):
                        encoded[f"{name}_{index}"] = member
            return encoded

        def check(label, overrides, diagnostic=None):
            result = invoke("validate", overrides)
            if diagnostic is None:
                passed = result.returncode == 0 and result.stdout and not result.stderr
            else:
                passed = (result.returncode != 0 and not result.stdout
                          and diagnostic.encode() in result.stderr)
            detail = result.stderr.decode(errors="replace").replace(str(root), "<fixture>")
            assert passed, f"{label}: exit {result.returncode}: {detail}"

        base = {"DEV_IMAGE": "debian:bookworm", "EPHEMERAL_HOME": "false"}
        check("omitted arrays", encode(base))
        check("explicitly empty arrays", encode({**base, "EGRESS_ALLOW": [], "READONLY_PATHS": [], "WRITABLE_PATHS": [], "HIDDEN_PATHS": []}))
        populated = {**base, "EGRESS_ALLOW": ["example.com", "api.example.com"],
                     "READONLY_PATHS": paths}
        check("multiple members and literal spaces/commas", encode(populated))
        check("writable indexed commas", encode({**base, "WRITABLE_PATHS": paths}))
        check("writable protection overlap", encode({**populated, "WRITABLE_PATHS": paths}), "protected")
        check("writable missing member", encode({**base, "WRITABLE_PATHS": ["missing-lane"]}), "missing-lane")
        check("hidden indexed commas", encode({**populated, "HIDDEN_PATHS": paths}))
        check("hidden missing member", encode({**base, "HIDDEN_PATHS": ["missing-mask"]}), "missing-mask")
        check("hidden duplicate", encode({**base, "HIDDEN_PATHS": [paths[0], paths[0]]}), "overlapping")
        # Combined many-member overlays have no application-defined maximum.
        lanes, protected = [], []
        for index in range(72):
            lane = project / f"lane-{index}"
            lane.mkdir(mode=0o755)
            (lane / "policy").write_text("protected")
            lanes.append(lane.name)
            protected.append(lane.name + "/policy")
        check("many combined overlays", encode({**base, "WRITABLE_PATHS": lanes, "READONLY_PATHS": protected, "HIDDEN_PATHS": protected}))
        check("image scalar consumed", encode({**base, "DEV_IMAGE": ""}), "Containerfile")
        check("retention scalar consumed", encode({**base, "EPHEMERAL_HOME": "invalid"}), "EPHEMERAL_HOME")
        # Both indices must affect validation, rather than merely being accepted.
        for index in range(2):
            missing = paths.copy()
            missing[index] = "missing-policy"
            check(f"path member {index} consumed", encode({**populated, "READONLY_PATHS": missing}),
                  "missing-policy")
        check("egress member consumed", encode({**populated, "EGRESS_ALLOW": ["example.com", "https://invalid"]}),
              "EGRESS_ALLOW")

        # Deliberately corrupt the consumer's valid encoding at the wire boundary.
        valid = encode(populated)
        name = prefix + "READONLY_PATHS"
        malformed = [
            ("mixed bare/indexed", {name: ""}, [], "mixes"),
            ("missing first index", {}, [name + "_0"], "gap"),
            ("leading zero", {name + "_00": paths[0]}, [name + "_0"], "malformed"),
            ("empty member", {name + "_1": ""}, [], "empty configuration array member"),
            ("nonempty bare array", {name: paths[0]}, [name + "_0", name + "_1"], "non-empty bare"),
        ]
        for label, additions, removals, diagnostic in malformed:
            overrides = {k: v for k, v in valid.items() if k not in removals}
            check(label, {**overrides, **additions}, diagnostic)
        assert not (root / "state").exists(), "discovery/validation wrote runtime state"
    print("PASS: schema-driven Python configuration consumer and encoding refusals")


if __name__ == "__main__":
    main()
