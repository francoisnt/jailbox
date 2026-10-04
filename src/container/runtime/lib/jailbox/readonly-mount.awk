BEGIN { target = ENVIRON["TARGET"]; expected = ENVIRON["EXPECTED"]; if (expected == "") expected = "ro"; found = 0; invalid = 0 }
{
    path = $5
    gsub(/\\040/, " ", path)
    gsub(/\\011/, "\t", path)
    gsub(/\\012/, "\n", path)
    gsub(/\\134/, "\\", path)
    if (expected ~ /^mask-/ && index(path, target "/") == 1) invalid = 1
    if (path != target) next
    found++
    if (expected == "mask-directory") {
        for (separator = 7; separator <= NF && $separator != "-"; separator++) {}
        if ($6 !~ /(^|,)ro(,|$)/ || $(separator + 1) != "tmpfs") invalid = 1
    } else if (expected != "mask-file") {
        if ($6 !~ ("(^|,)" expected "(,|$)")) invalid = 1
    }
    # A mask must be private, independently of the project bind propagation.
    if (expected ~ /^mask-/) {
        for (option = 7; option <= NF && $option != "-"; option++)
            if ($option ~ /^(shared|master|propagate_from):/) invalid = 1
    }
}
END { exit !(found == 1 && !invalid) }
