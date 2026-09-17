$0 ~ "^[[:space:]]*" array "=[(]" { in_array = 1; next }
in_array && /^[[:space:]]*[)]/ { in_array = 0; next }
in_array {
    gsub(/#.*/, "")
    gsub(/["'"]/, "")
    for (i = 1; i <= NF; i++) print $i
}
