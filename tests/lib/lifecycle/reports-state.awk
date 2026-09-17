{
    gsub(/[^[:alnum:]_-]+/, " ")
    named=0; observed=0
    for (i=1; i<=NF; i++) {
        if ($i == name) named=1
        if ($i == state) observed=1
    }
    if (named && observed) found=1
}
END { exit !found }
