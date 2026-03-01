#!/usr/bin/env python3
"""
Demo Agent - Executes tasks and submits evidence to escrow contract.
Reads config from env vars: MISSION_ID, ESCROW_CONTRACT, RPC_URL, AGENT_PRIVATE_KEY, GITHUB_REPO
"""

import json
import os
import subprocess
import hashlib
import sys
import threading
import time
import requests
from pathlib import Path

# Config from environment
MISSION_ID = os.environ.get("MISSION_ID")
ESCROW_CONTRACT = os.environ.get("ESCROW_CONTRACT")
RPC_URL = os.environ.get("RPC_URL", "http://localhost:8545")
AGENT_PRIVATE_KEY = os.environ.get("AGENT_PRIVATE_KEY")
GITHUB_REPO = os.environ.get("GITHUB_REPO")
HEARTBEAT_URL = os.environ.get("HEARTBEAT_URL", "http://localhost:8080/heartbeat")

REQUIRED_VARS = ["MISSION_ID", "ESCROW_CONTRACT", "AGENT_PRIVATE_KEY", "GITHUB_REPO"]


def print_step(step: str, msg: str):
    """Print step-by-step progress."""
    print(f"[{step}] {msg}")


def check_env():
    """Validate required environment variables."""
    missing = [v for v in REQUIRED_VARS if not os.environ.get(v)]
    if missing:
        print(f"Error: Missing required env vars: {', '.join(missing)}")
        sys.exit(1)
    print_step("ENV", f"MISSION_ID={MISSION_ID}, REPO={GITHUB_REPO}")


def clone_repo():
    """Clone the GitHub repo to a temp directory."""
    repo_dir = Path(f"/tmp/repo-{MISSION_ID}")
    if repo_dir.exists():
        print_step("CLONE", "Repo already exists, skipping clone")
        return repo_dir

    print_step("CLONE", f"Cloning {GITHUB_REPO}...")
    result = subprocess.run(
        ["git", "clone", f"https://github.com/{GITHUB_REPO}.git", str(repo_dir)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print_step("CLONE", f"Failed: {result.stderr}")
        sys.exit(1)
    print_step("CLONE", f"Cloned to {repo_dir}")
    return repo_dir


def run_lint(repo_dir: Path) -> tuple[int, str]:
    """Run lint command in the repo."""
    print_step("LINT", "Checking for npm/package.json...")

    # Check if npm project
    if (repo_dir / "package.json").exists():
        print_step("LINT", "Running npm install && npm run lint...")
        result = subprocess.run(
            ["npm", "install"],
            cwd=repo_dir,
            capture_output=True,
            text=True,
            timeout=300,
        )
        if result.returncode != 0:
            print_step("LINT", f"npm install failed: {result.stderr}")

        result = subprocess.run(
            ["npm", "run", "lint"],
            cwd=repo_dir,
            capture_output=True,
            text=True,
            timeout=120,
        )
    else:
        # No npm, just echo lint-ok
        print_step("LINT", "No package.json found, using echo lint-ok")
        result = subprocess.run(
            ["echo", "lint-ok"],
            capture_output=True,
            text=True,
        )

    output = result.stdout + result.stderr
    print_step("LINT", f"Exit code: {result.returncode}")
    return result.returncode, output


def write_evidence(exit_code: int, lint_output: str) -> str:
    """Write evidence to JSON file and return SHA256 hash."""
    evidence_file = Path(f"evidence-{MISSION_ID}.json")

    evidence = {
        "mission_id": MISSION_ID,
        "exit_code": exit_code,
        "lint_output": lint_output,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    with open(evidence_file, "w") as f:
        json.dump(evidence, f, indent=2)

    # Compute SHA256
    sha256_hash = hashlib.sha256(evidence_file.read_bytes()).hexdigest()
    print_step("EVIDENCE", f"Written to {evidence_file}, SHA256: {sha256_hash}")
    return sha256_hash


def submit_on_chain(evidence_hash: str):
    """Submit evidence hash to escrow contract via cast send."""
    print_step("SUBMIT", f"Calling submitEAL({MISSION_ID}, {evidence_hash})...")

    cmd = [
        "cast",
        "send",
        ESCROW_CONTRACT,
        "submitEAL(bytes32,bytes32)",
        MISSION_ID,
        evidence_hash,
        "--rpc-url",
        RPC_URL,
        "--private-key",
        AGENT_PRIVATE_KEY,
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print_step("SUBMIT", f"Failed: {result.stderr}")
        sys.exit(1)

    print_step("SUBMIT", f"Transaction submitted: {result.stdout.strip()}")


def heartbeat_loop():
    """Send heartbeat every 60 seconds in background."""
    while True:
        try:
            requests.get(HEARTBEAT_URL, timeout=5)
            print_step("HEARTBEAT", "Sent heartbeat")
        except Exception as e:
            print_step("HEARTBEAT", f"Failed: {e}")
        time.sleep(60)


def main():
    print("=" * 50)
    print("DEMO AGENT - Starting")
    print("=" * 50)

    check_env()

    # Start heartbeat in background
    heartbeat_thread = threading.Thread(target=heartbeat_loop, daemon=True)
    heartbeat_thread.start()

    # Do work
    repo_dir = clone_repo()
    exit_code, lint_output = run_lint(repo_dir)

    # Write evidence
    evidence_hash = write_evidence(exit_code, lint_output)

    # Submit on-chain
    submit_on_chain(evidence_hash)

    print("=" * 50)
    print("DEMO AGENT - Complete!")
    print("=" * 50)


if __name__ == "__main__":
    main()
