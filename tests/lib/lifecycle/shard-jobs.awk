# Input: group weight|group|weight|job records, heaviest group first. Give each
# group to the least-loaded shard (lowest number on ties) and print the job
# records owned by `shard`.
$2 != current {
    current = $2; best = 1
    for (i = 2; i <= count; i++) if (load[i] < load[best]) best = i
    load[best] += $1
}
best == shard { sub(/^[^|]*\|[^|]*\|[^|]*\|/, ""); print }
