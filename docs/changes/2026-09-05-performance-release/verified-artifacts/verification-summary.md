# Offline verification

Executed on the local arm64 Mac with `DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer` (Swift 6.3.2).

- `python3 scripts/verify.py`: exit 0. At source revision `2feebbe34fcb03bcdda3f4476f6a15790b14e832`, 12 release-controller tests, 149 XCTest cases, and all 15 independent verification executables passed.
- `EQUIV_ROUNDS=100 EQUIV_SEED=42 .build/release/DerivedFinalizeEquivalence`: exit 0. Includes 40-node closure fallback, SQLite error propagation, network bucket relocation, consistent summary/series snapshots, and failed-read rollback.
- `BENCH_EVENT_COUNT=200000 BENCH_REQUIRE_RATIO=1 /usr/bin/time -l .build/release/DerivedFinalizeBenchmark`: exit 0. See `baseline.json` and `optimized-benchmark.json` for the same-workload comparison.
- Real FSEvents discovery, directory-permission recovery, alias deletion, stream replacement/restart, cross-batch parsing, parser-state privacy, CPA migration/backfill/audit, acknowledgement revisions and coordinator recovery were exercised by the independent executables or XCTest cases, not inferred from compilation.

## Findings resolved during verification

- Follow-up review verification covers coalesced token acquisition, overlapping forced refresh after initial failure, identity fencing, waiter cancellation, stale-flight results, buffered network response boundaries/cancellation, missing analytics identities, and preservation of original fixture failures during cleanup.
- Two deterministic tests cancel the actor-backed test clock before continuation registration and before sleep entry. They pass without cancelled-ID bookkeeping; the proposed registration race does not occur under the current actor isolation.
- The accepted 200-event benchmark now generates session activity and passes its exact work-scope/resource assertions; the 20k/200k fixture distribution remains unchanged. Benchmark metadata now identifies an immutable measured source revision.
- Normalized both FSEvents paths and enumeration-error paths; macOS can supply `/private/var` while Foundation uses `/var`. Permission recovery and real notifications now pass without changing sampling frequency.
- Corrected old tests that used 1970 sample timestamps with a real clock, used fixture filenames rejected by the original collector contract, or expected superseded hostname/R2 configuration contracts. Exact behavior and security assertions remain.
- Replaced changed calendar-contract source checks with real cross-timezone snapshots and coordinator bootstrap/scan behavior. No production data was used in these fixtures.

## Scope and remaining limits

- FSEvents startup failure still propagates during collector initialization. A continuously scanning fallback preserves discovery but increases sustained I/O while monitoring remains unavailable; freezing discovery does not preserve new-file visibility. This policy decision is pending, not claimed resolved by the normal-path FSEvents tests.
- These are finite synthetic and integration tests, not a 48-hour production soak. Stable DB/WAL/named temporary files do not prove an upper bound on transient unlinked SQLite files.
- Parser identity state necessarily grows with retained historical identities. No historical records, production database, or backups were deleted. A single JSON record still determines the minimum per-record memory requirement.
- Append-log guards detect observed prefix/tail/identity changes; arbitrary same-inode middle rewrites that preserve those guards cannot be guaranteed detectable without rescanning.
- CPA audit handles arbitrarily late events eventually; no monotonic event-time assumption or undocumented server tombstone/delete protocol is introduced. End-to-end deletion of an already uploaded old bucket remains outside the proven server contract.
- Desktop UI evidence is kept locally and is not committed to the public repository. CI, final release and installed-bundle identity require their own subsequent verification.
