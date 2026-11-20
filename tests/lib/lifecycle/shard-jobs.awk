# Input: weight|job records, heaviest first. Give each job to the least-loaded
# shard (lowest number on ties) and print the job records owned by `shard`.
{
    best = 1
    for (i = 2; i <= count; i++) if (load[i] < load[best]) best = i
    load[best] += $1
}
best == shard { sub(/^[^|]*\|/, ""); print }
