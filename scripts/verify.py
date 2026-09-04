"""Run deterministic offline verification without production databases or credentials."""

import argparse
import os
from pathlib import Path
import subprocess

PROJECT = Path(__file__).resolve().parent.parent
TARGETS = (
    "AgentPulseCoreVerification", "AgentPulseCollectorVerification",
    "AgentPulseR2Verification", "AgentPulseReportingVerification",
    "AgentPulseUsageVerification", "MetricsLedgerPipelineVerification",
    "RuntimeHeaderParityVerification", "NaturalKeyGuardVerification",
    "SecureConfigVerification", "LedgerRebuildVerification",
    "ScanProgressSmootherVerification", "DerivedFinalizeEquivalence",
    "DerivedFinalizeBenchmark", "IncrementalParserVerification", "CliProxyPipelineVerification",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    args = parser.parse_args()
    environment = os.environ.copy()
    environment.update(BENCH_EVENT_COUNT="20000", EQUIV_ROUNDS="20", EQUIV_SEED="7")
    # ReconcileParityVerification's live path reads local config and credentials;
    # it is intentionally not an offline gate. Pure reconcile checks live in tests.
    environment.pop("AGENT_PULSE_RECONCILE_REQUIRE_LIVE", None)
    environment.pop("BENCH_REQUIRE_RATIO", None)
    subprocess.run(["python3", str(PROJECT / "scripts/test_release.py")], cwd=PROJECT, check=True)
    subprocess.run(["swift", "build", "-c", args.configuration], cwd=PROJECT, env=environment, check=True)
    subprocess.run(["swift", "test", "-c", args.configuration], cwd=PROJECT, env=environment, check=True)
    for target in TARGETS:
        print(f"\nVerifying {target}", flush=True)
        subprocess.run(["swift", "run", "--skip-build", "-c", args.configuration, target],
                       cwd=PROJECT, env=environment, check=True)


if __name__ == "__main__":
    main()
