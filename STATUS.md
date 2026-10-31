# Complete — 2026-10-31 UTC

Published at the user's explicit request: https://github.com/gbaraldi/WasmCodegen.jl/issues/43 (posted body verified).

- REPORT.md contains all three tables, startup, wall/RSS and phase appendices, recommendations, every runner patch, corrections, raw-data references and exact rerun commands.
- 430 correctness gates pass. All expected five-round groups pass the final audit: 645 Table 1 rows, 120 IO rows, 340 Pkg sweep rows, 510 IO sweep rows, 25 startup rows and 110 optimizer-cost rows. Four source checkouts remain clean at the pinned commits. See out/audit.json.
- Blocked: O4 asserts in Binaryen 130 on both modules. Persisted fresh-process Module caching is unavailable through the tested Node API; same-process reuse is distinguished in the report. No IO candidate was skipped.
- Recommendation: retain O3/default Node settings; Os is an optional size/memory tradeoff; prioritize metadata imports and small-write coalescing. tnh remains unsafe despite passing fixtures.
- Corrections: deterministic registry-age setup for three committed baselines; M4 stable physical warm cache and usage-log paths; Node eager-compilation keepalive on both paired sides. Preliminary invalid data is excluded and documented.
- Workspace disk footprint fell from 161.97 GiB to 10.02 GiB after pruning (151.95 GiB reclaimed); the filesystem has 331.98 GiB free at completion. Full base references, fixtures, modules, all CSV/logs/captured hashes and timing records remain. Allocation scans: out/disk-usage.txt and out/disk-usage-after-prune.txt; exact removed paths: out/pruned-depots.json.

No benchmark batches remain running. Full progress history: out/STATUS-runlog.md.
