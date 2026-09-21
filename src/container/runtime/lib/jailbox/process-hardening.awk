/^CapEff:/ { caps = ($2 == "0000000000000000"); seen_caps = 1 }
/^CapBnd:/ { bound = ($2 == "0000000000000000"); seen_bound = 1 }
/^NoNewPrivs:/ { nnp = ($2 == "1"); seen_nnp = 1 }
END { exit !(seen_caps && caps && seen_bound && bound && seen_nnp && nnp) }
