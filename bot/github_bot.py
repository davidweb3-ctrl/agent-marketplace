#!/usr/bin/env python3
"""
GitHub Bot - Polls repo for new issues with label 'agent-task',
parses TDL YAML, creates mission on-chain, posts comment.
"""

import os
import time
import yaml
import re
import sys
import subprocess
from github import Github
from pathlib import Path

# Config from environment
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN")
GITHUB_REPO = os.environ.get("GITHUB_REPO")  # e.g., "owner/repo"
ESCROW_CONTRACT = os.environ.get("ESCROW_CONTRACT")
RPC_URL = os.environ.get("RPC_URL", "http://localhost:8545")
DEPLOYER_PRIVATE_KEY = os.environ.get("DEPLOYER_PRIVATE_KEY")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "30"))

REQUIRED_VARS = [
    "GITHUB_TOKEN",
    "GITHUB_REPO",
    "ESCROW_CONTRACT",
    "DEPLOYER_PRIVATE_KEY",
]


def check_env():
    """Validate required environment variables."""
    missing = [v for v in REQUIRED_VARS if not os.environ.get(v)]
    if missing:
        print(f"Error: Missing required env vars: {', '.join(missing)}")
        sys.exit(1)


def parse_tdl_yaml(issue_body: str) -> dict | None:
    """Parse TDL YAML from issue body (field: 'tdl:')."""
    # Look for tdl: followed by yaml block
    pattern = r"```tdl\n(.*?)```"
    match = re.search(pattern, issue_body, re.DOTALL)

    if not match:
        # Try inline format: tdl: |
        pattern2 = r"tdl:\s*\|(.*?)(?:\n\n|\Z)"
        match2 = re.search(pattern2, issue_body, re.DOTALL)
        if not match2:
            print("No TDL block found in issue body")
            return None

        yaml_str = match2.group(1).strip()
    else:
        yaml_str = match.group(1).strip()

    try:
        tdl = yaml.safe_load(yaml_str)
        return tdl
    except yaml.YAMLError as e:
        print(f"Failed to parse TDL: {e}")
        return None


def create_mission_on_chain(
    mission_id: str, agent: str, reward: int, duration_minutes: int
) -> str:
    """Call createMission via cast send."""
    print(f"[CHAIN] Creating mission {mission_id}...")

    cmd = [
        "cast",
        "send",
        ESCROW_CONTRACT,
        "createMission(bytes32,address,uint256,uint256)",
        mission_id,
        agent,
        str(reward),
        str(duration_minutes),
        "--rpc-url",
        RPC_URL,
        "--private-key",
        DEPLOYER_PRIVATE_KEY,
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"[CHAIN] Failed: {result.stderr}")
        sys.exit(1)

    # Extract tx hash from output
    tx_hash = result.stdout.strip().split("\n")[-1]
    print(f"[CHAIN] Mission created, tx: {tx_hash}")
    return tx_hash


def post_comment(issue, tx_hash: str):
    """Post GitHub comment with tx info."""
    comment_body = f"⚡ Mission created on-chain: {tx_hash}"
    issue.create_comment(comment_body)
    print(f"[GITHUB] Comment posted: {comment_body}")


def process_issue(issue):
    """Process a single issue with agent-task label."""
    print(f"[ISSUE] Processing #{issue.number}: {issue.title}")

    # Check if already processed
    for comment in issue.get_comments():
        if "Mission created on-chain:" in comment.body:
            print(f"[ISSUE] Already processed, skipping")
            return

    # Parse TDL
    tdl = parse_tdl_yaml(issue.body)
    if not tdl:
        print(f"[ISSUE] No valid TDL found")
        return

    # Extract mission params
    mission_id = tdl.get("mission_id") or tdl.get("id")
    agent = tdl.get("agent", "0x0000000000000000000000000000000000000000")
    reward = tdl.get("reward", 0)
    duration = tdl.get("duration_minutes", 60)

    if not mission_id:
        print(f"[ISSUE] No mission_id in TDL")
        return

    print(
        f"[ISSUE] Mission: {mission_id}, agent={agent}, reward={reward}, duration={duration}"
    )

    # Create on-chain
    tx_hash = create_mission_on_chain(mission_id, agent, reward, duration)

    # Post comment
    post_comment(issue, tx_hash)


def poll_issues(gh, repo_name: str):
    """Poll repo for new issues with agent-task label."""
    print(f"[POLL] Watching {repo_name} for issues with 'agent-task' label...")

    repo = gh.get_repo(repo_name)

    while True:
        try:
            # Get open issues with agent-task label
            issues = repo.get_issues(
                state="open",
                labels=["agent-task"],
            )

            for issue in issues:
                if issue.pull_request:
                    continue  # Skip PRs
                process_issue(issue)

        except Exception as e:
            print(f"[POLL] Error: {e}")

        time.sleep(POLL_INTERVAL)


def main():
    print("=" * 50)
    print("GITHUB BOT - Starting")
    print("=" * 50)

    check_env()

    gh = Github(GITHUB_TOKEN)
    poll_issues(gh, GITHUB_REPO)


if __name__ == "__main__":
    main()
