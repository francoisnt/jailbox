$5 == target { self = $6 }
index($5, prefix) == 1 && $6 !~ /(^|,)ro(,|$)/ { nested = nested " " $5 }
END {
    if (self == "") print "absent"
    else if (self !~ /(^|,)ro(,|$)/) print "writable:" self
    else if (nested != "") print "nested:" nested
    else print "ok"
}
