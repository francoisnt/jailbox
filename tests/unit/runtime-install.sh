#!/bin/bash
# Exercise the real POSIX installer without package or account setup.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sed -n '/^install_runtime_tree()/,/^)/p' "$ROOT/src/container/setup.sh" > "$tmp/install.sh"
cat >> "$tmp/install.sh" <<'CALLS'
install_runtime_tree "$1/bin" "$2/bin" 0755 || exit 1
install_runtime_tree "$1/lib" "$2/lib" 0644 || exit 1
CALLS
mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}
for mask in 0022 0002 0077; do
    source_dir="$tmp/source-$mask"
    destination="$tmp/destination-$mask"
    mkdir -p "$source_dir" "$destination/bin" "$destination/lib"
    cp -R "$ROOT/src/container/runtime/." "$source_dir/"
    mkdir -p "$source_dir/lib/jailbox/future" "$source_dir/lib/jailbox/new"
    mkdir -p "$destination/lib/jailbox/future"
    chmod 0700 "$destination/lib/jailbox" "$destination/lib/jailbox/future"
    printf 'preserved data\n' > "$destination/lib/jailbox/unrelated"
    chmod 0600 "$destination/lib/jailbox/unrelated"
    printf '#!/bin/sh\nprintf future\\n\n' > "$source_dir/bin/future-helper"
    printf 'future data\n' > "$source_dir/lib/jailbox/future/.data"
    # Model sources copied by an installer using a restrictive umask.
    find "$source_dir" -type d -exec chmod 0700 {} +
    find "$source_dir" -type f -exec chmod 0600 {} +
    printf 'unrelated\n' > "$destination/lib/unrelated"
    chmod 0700 "$destination/lib/unrelated"
    chmod 0750 "$destination/bin" "$destination/lib"
    # Existing shipped files also need their permissions corrected.
    printf 'old helper\n' > "$destination/bin/future-helper"
    chmod 0600 "$destination/bin/future-helper"
    (umask "$mask"; sh "$tmp/install.sh" "$source_dir" "$destination")
    while IFS= read -r file; do
        relative=${file#"$source_dir/"}
        cmp "$file" "$destination/$relative"
        case "$relative" in
            bin/*) [[ $(mode "$destination/$relative") = 755 ]] ;;
            lib/*) [[ $(mode "$destination/$relative") = 644 ]] ;;
        esac
    done < <(find "$source_dir" -type f -print)
    [[ $(mode "$destination/lib/jailbox") = 755 ]]
    [[ $(mode "$destination/lib/jailbox/future") = 755 ]]
    [[ $(mode "$destination/lib/jailbox/new") = 755 ]]
    [[ $(mode "$destination/lib/jailbox/unrelated") = 600 ]]
    [[ $(cat "$destination/lib/jailbox/unrelated") = 'preserved data' ]]
    [[ $(mode "$destination/bin") = 750 ]]
    [[ $(mode "$destination/lib") = 750 ]]
    [[ $(mode "$destination/lib/unrelated") = 700 ]]
    [[ $(cat "$destination/lib/unrelated") = unrelated ]]
    # A failed first subtree must stop installation before the library phase.
    mkdir "$source_dir/bin/blocked"
    printf 'collision\n' > "$destination/bin/blocked"
    printf 'must not install\n' > "$source_dir/lib/later"
    if sh "$tmp/install.sh" "$source_dir" "$destination" 2>/dev/null; then
        echo 'installer accepted a directory/file collision' >&2
        exit 1
    fi
    [[ ! -e "$destination/lib/later" ]]
done
echo 'Runtime installation: discovery, permissions, preservation, and failure checks passed'
