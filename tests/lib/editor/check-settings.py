"""Independent JSON round-trip oracle for the generated frontend settings."""
import json
import pathlib
import sys

path, ssh_config, proxy_url = sys.argv[1:]
expected = {"remote.SSH.configFile": ssh_config}
if proxy_url:
    expected["http.proxy"] = proxy_url
assert json.loads(pathlib.Path(path).read_text(encoding="utf-8")) == expected
