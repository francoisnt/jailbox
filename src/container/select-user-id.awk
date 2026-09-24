# Select one non-root ID unused by both passwd and group. A shared UID/GID
# makes the managed primary group explicit across Debian and Alpine tools.
BEGIN { FS = ":" }
{ used[$3] = 1 }
END {
    if (preferred ~ /^[1-9][0-9]*$/ && preferred <= 60000 && !used[preferred]) {
        print preferred
        exit
    }
    for (candidate = 1000; candidate <= 60000; candidate++) {
        if (!used[candidate]) { print candidate; exit }
    }
    exit 1
}
