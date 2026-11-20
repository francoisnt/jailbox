# Read weight|job records twice. Pieces of a split sweep (key suffix .pN) form
# one group so they always share a machine; print group weight|group|record.
function group(key) { sub(/\.p[1-9]$/, "", key); return key }
NR == FNR { total[group($2)] += $1; next }
{ print total[group($2)] "|" group($2) "|" $0 }
