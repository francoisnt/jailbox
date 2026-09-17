function group(k, a) {
    if (k ~ /^interrupt\./) { split(k,a,"."); return "interruptions " a[2] "/" a[3] }
    if (k ~ /^trace\./) return "discovery"
    if (k ~ /^(failed-|home-inspection\.)/) return "targeted failures"
    return "matrix"
}
group($0) == group(key) { total++; if ($0 == key) number=total }
END { if (!number) exit 1; printf "CASE [%s %d/%d] %s\n",group(key),number,total,key }
