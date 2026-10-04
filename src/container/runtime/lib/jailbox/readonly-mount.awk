BEGIN { target = ENVIRON["TARGET"]; expected = ENVIRON["EXPECTED"]; if (expected == "") expected = "ro"; found = 0; invalid = 0 }
{
    path = $5
    gsub(/\\040/, " ", path)
    gsub(/\\011/, "\t", path)
    gsub(/\\012/, "\n", path)
    gsub(/\\134/, "\\", path)
    if (path != target) next
    found++
    if ($6 !~ ("(^|,)" expected "(,|$)")) invalid = 1
}
END { exit !(found == 1 && !invalid) }
