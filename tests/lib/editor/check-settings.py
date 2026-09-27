"""Independent JSON round-trip oracle for the generated frontend settings."""
import json
import pathlib
import sys

path, ssh_config, proxy_url = sys.argv[1:]
expected = {"remote.SSH.configFile": ssh_config,
            "remote.SSH.enableAgentForwarding": False}
if proxy_url:
    expected["http.proxy"] = proxy_url
settings_path = pathlib.Path(path)
try:
    label = str(settings_path.resolve().relative_to(pathlib.Path.cwd().resolve()))
except ValueError:
    label = str(settings_path)
try:
    actual = json.loads(settings_path.read_text(encoding="utf-8"))
except (OSError, ValueError) as error:
    sys.exit(f"Cannot read editor settings {label}: {error}")
if not isinstance(actual, dict):
    sys.exit(f"Editor settings mismatch in {label}: expected a JSON object")
differences = []
for key, value in expected.items():
    if key not in actual:
        differences.append(f"{key}: missing; expected {value!r}")
    elif type(actual[key]) is not type(value) or actual[key] != value:
        differences.append(f"{key}: expected {value!r}; got {actual[key]!r}")
for key in actual.keys() - expected.keys():
    differences.append(f"unexpected setting: {key}")
if differences:
    sys.exit(f"Editor settings mismatch in {label}:\n  " + "\n  ".join(differences))
