BEGIN {
    split(ENVIRON["EXPECTED_GATEWAY"], octets, ".")
    expected = sprintf("%02X%02X%02X%02X", octets[4], octets[3], octets[2], octets[1])
}
NR > 1 && $2 == "00000000" { count++; if ($3 != expected) bad = 1 }
END { exit !(count == 1 && !bad) }
