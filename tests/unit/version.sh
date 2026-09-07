#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/source" "$tmp/project" "$tmp/bin"
cp -R "$ROOT/jailbox" "$ROOT/host" "$ROOT/container" "$ROOT/scripts" \
    "$ROOT/install.sh" "$ROOT/README.md" "$tmp/source/"
cat > "$tmp/bin/podman" <<'STUB'
#!/bin/bash
echo 'Podman must not be called' >&2
exit 99
STUB
chmod +x "$tmp/bin/podman"
export PATH="$tmp/bin:$PATH"
# shellcheck disable=SC2016 # Deliberate shell syntax must remain inert data.
printf 'invalid configuration $(touch should-not-exist)\n' > "$tmp/project/jailbox.conf"
cd "$tmp/project"
export JAILBOX_CONFIG_UNDECLARED=invalid
bash "$tmp/source/jailbox" --version > "$tmp/out" 2> "$tmp/err"
printf 'jailbox dev\n' > "$tmp/expected"
cmp "$tmp/expected" "$tmp/out"
[[ ! -s "$tmp/err" && ! -e should-not-exist ]]
[[ $(bash "$tmp/source/jailbox" --config /missing --version) == 'jailbox dev' ]]
if bash "$tmp/source/jailbox" --version extra > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
[[ ! -s "$tmp/out" ]]

for value in '' 'garbage' '1.2.3' $'1.2.3\n\n' $'01.2.3\n' $'1.2.3\r\n' $'1.2.3\nother\n'; do
    printf '%s' "$value" > "$tmp/source/VERSION"
    if bash "$tmp/source/jailbox" --version > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
    [[ ! -s "$tmp/out" && -s "$tmp/err" ]]
done
printf '1.2.3\0\n' > "$tmp/source/VERSION"
if bash "$tmp/source/jailbox" --version > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
[[ ! -s "$tmp/out" && -s "$tmp/err" ]]
printf '1.2.3\n' > "$tmp/source/VERSION"
[[ $(bash "$tmp/source/jailbox" --version) == 'jailbox 1.2.3' ]]
if bash "$tmp/source/scripts/build-tarball.sh" v1.2.4 > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
grep -q 'existing VERSION stamp' "$tmp/err"
rm "$tmp/source/VERSION"
ln -s /missing-stamp "$tmp/source/VERSION"
if bash "$tmp/source/jailbox" --version > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
[[ ! -s "$tmp/out" && -s "$tmp/err" ]]
if bash "$tmp/source/scripts/build-tarball.sh" v1.2.4 > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
rm "$tmp/source/VERSION"

bash "$tmp/source/scripts/build-tarball.sh" v1.2.3 > /dev/null
[[ ! -e "$tmp/source/VERSION" ]]
dist="$tmp/source/dist"
mkdir "$tmp/extracted"
tar -xzf "$dist/jailbox-v1.2.3.tar.gz" -C "$tmp/extracted"
tree="$tmp/extracted/jailbox-v1.2.3"

repack() {
    (cd "$tmp/extracted" && tar -czf "$dist/jailbox-v1.2.3.tar.gz" jailbox-v1.2.3)
    cp "$dist/jailbox-v1.2.3.tar.gz" "$dist/jailbox-latest.tar.gz"
    (
        cd "$dist"
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum jailbox-v1.2.3.tar.gz jailbox-latest.tar.gz
        else
            shasum -a 256 jailbox-v1.2.3.tar.gz jailbox-latest.tar.gz
        fi
    ) > "$dist/SHA256SUMS"
}
reject_artifact() {
    repack
    if bash "$ROOT/scripts/validate-release.sh" v1.2.3 "$dist" > "$tmp/out" 2> "$tmp/err"; then exit 1; fi
    [[ -s "$tmp/err" ]]
}
rm "$tree/VERSION"
reject_artifact
printf 'malformed\n' > "$tree/VERSION"
reject_artifact
printf '1.2.4\n' > "$tree/VERSION"
reject_artifact
printf '1.2.3\n' > "$tree/VERSION"
for body in "printf 'jailbox 1.2.4\\n'" "printf 'jailbox 1.2.3\\n\\n'" "printf 'jailbox 1.2.3\\n'; echo warning >&2" 'exit 1'; do
    printf '#!/bin/bash\n%s\n' "$body" > "$tree/jailbox"
    reject_artifact
done
cp "$ROOT/jailbox" "$tree/jailbox"
repack
bash "$ROOT/scripts/validate-release.sh" v1.2.3 "$dist"
printf 'bad\n' > "$dist/SHA256SUMS"
if bash "$ROOT/scripts/validate-release.sh" v1.2.3 "$dist" > /dev/null 2>&1; then exit 1; fi
repack
printf 'different' >> "$dist/jailbox-latest.tar.gz"
if bash "$ROOT/scripts/validate-release.sh" v1.2.3 "$dist" > /dev/null 2>&1; then exit 1; fi
echo 'Version and artifact tests passed'
