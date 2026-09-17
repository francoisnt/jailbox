FILENAME == ARGV[1] {
    if (NF != 2 || $1 !~ /^[a-z][a-z0-9.-]*$/ || $2 !~ /^[0-9]+$/ || length($2) > 9) {
        bad=1; exit 1
    }
    duration[$1]=$2; next
}
{ priority=($1 in duration) ? duration[$1] : ($2 == "fault" ? 1000000000 : ($3 == "inspection" ? 100 : 0))
  print priority "|" $0 }
END { if (bad) print "Invalid lifecycle timing record" > "/dev/stderr" }
