function group(k) {
    if (k ~ /^interrupt\./) return "interruptions"
    if (k ~ /^trace\./) return "discovery"
    if (k ~ /^(failed-|home-inspection\.)/) return "targeted"
    return "matrix"
}
FILENAME ~ /\/cases$/ { done[group($1)]++; finished++; next }
{ total[group($1)]++; expected++ }
END {
    provisional=(done["discovery"] < total["discovery"])
    printf "Progress: %d/%d%s completed | matrix %d/%d | discovery %d/%d | interruptions %d/%d%s | targeted %d/%d\n", \
        finished,expected,(provisional ? " known" : ""),done["matrix"],total["matrix"], \
        done["discovery"],total["discovery"],done["interruptions"],total["interruptions"], \
        (provisional ? " known (discovering)" : ""),done["targeted"],total["targeted"]
}
