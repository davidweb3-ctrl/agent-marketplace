#!/usr/bin/env python3
"""Tests for agent_demo.py - Agent execution, evidence creation, and EAL submission."""

import pytest
import json
import hashlib
import tempfile
import os
from pathlib import Path
from unittest.mock import Mock, patch, MagicMock


@pytest.fixture
def temp_repo_dir(tmp_path):
    """Create a temporary directory for repo simulation."""
    repo_dir = tmp_path / "repo-test"
    repo_dir.mkdir()
    return repo_dir


@pytest.fixture
def mock_env(temp_repo_dir):
    """Mock environment variables for agent_demo."""
    env_vars = {
        "MISSION_ID": "0xdeadbeef12345678",
        "ESCROW_CONTRACT": "0x1234567890123456789012345678901234567890",
        "RPC_URL": "http://localhost:8545",
        "AGENT_PRIVATE_KEY": "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
        "GITHUB_REPO": "test-owner/test-repo",
    }
    with patch.dict(os.environ, env_vars, clear=True):
        yield env_vars


class TestRunLint:
    """Tests for run_lint function."""

    @patch("subprocess.run")
    def test_run_lint_npm_project(self, mock_run, mock_env, temp_repo_dir):
        """Test lint on npm project."""
        from agent_demo import run_lint

        # Create package.json to simulate npm project
        (temp_repo_dir / "package.json").write_text('{"name": "test"}')

        mock_run.return_value = Mock(returncode=0, stdout="lint passed", stderr="")

        exit_code, output = run_lint(temp_repo_dir)

        assert exit_code == 0

    @patch("subprocess.run")
    def test_run_lint_no_package_json(self, mock_run, mock_env, temp_repo_dir):
        """Test lint on non-npm project."""
        from agent_demo import run_lint

        mock_run.return_value = Mock(returncode=0, stdout="lint-ok", stderr="")

        exit_code, output = run_lint(temp_repo_dir)

        assert exit_code == 0
        assert "lint-ok" in output


class TestWriteEvidence:
    """Tests for write_evidence function."""

    def test_evidence_file_created(self, mock_env, tmp_path):
        """Test: evidence file is created after 'work' runs."""
        from agent_demo import write_evidence, MISSION_ID

        with patch("agent_demo.MISSION_ID", "0xdeadbeef12345678"):
            evidence_file = tmp_path / "evidence-0xdeadbeef12345678.json"
            with patch("pathlib.Path", return_value=evidence_file):
                exit_code = 0
                lint_output = "lint passed"
                sha256_hash = write_evidence(exit_code, lint_output)

        assert evidence_file.exists()

    def test_evidence_file_contains_output_and_exit_code(self, mock_env, tmp_path):
        """Test: evidence file contains output and exit_code fields."""
        from agent_demo import write_evidence, MISSION_ID

        with patch("agent_demo.MISSION_ID", "0xdeadbeef12345678"):
            evidence_file = tmp_path / "evidence-0xdeadbeef12345678.json"
            with patch("pathlib.Path", return_value=evidence_file):
                exit_code = 0
                lint_output = "lint passed successfully"
                sha256_hash = write_evidence(exit_code, lint_output)

        # Read and verify content
        with open(evidence_file) as f:
            evidence = json.load(f)

        assert "exit_code" in evidence
        assert "lint_output" in evidence
        assert evidence["exit_code"] == 0
        assert "lint passed successfully" in evidence["lint_output"]
        assert "mission_id" in evidence
        assert "timestamp" in evidence

    def test_sha256_of_evidence_computed_correctly(self, mock_env, tmp_path):
        """Test: sha256 of evidence is computed correctly."""
        from agent_demo import write_evidence, MISSION_ID

        with patch("agent_demo.MISSION_ID", "0xdeadbeef12345678"):
            evidence_file = tmp_path / "evidence-0xdeadbeef12345678.json"
            with patch("pathlib.Path", return_value=evidence_file):
                exit_code = 0
                lint_output = "test output"
                sha256_hash = write_evidence(exit_code, lint_output)

        # Verify SHA256 matches manual computation
        with open(evidence_file, "rb") as f:
            expected_hash = hashlib.sha256(f.read()).hexdigest()

        assert sha256_hash == expected_hash
        assert len(sha256_hash) == 64  # SHA256 hex length


class TestSubmitOnChain:
    """Tests for submit_on_chain function."""

    @patch("subprocess.run")
    def test_submit_eal_builds_correct_cast_command(self, mock_run, mock_env):
        """Test: submitEAL builds correct cast command (mock subprocess)."""
        from agent_demo import submit_on_chain

        mock_run.return_value = Mock(returncode=0, stdout="0xtxhash456\n", stderr="")

        evidence_hash = "0xabc123def456"

        with patch("agent_demo.MISSION_ID", "0xdeadbeef12345678"):
            with patch(
                "agent_demo.ESCROW_CONTRACT",
                "0x1234567890123456789012345678901234567890",
            ):
                with patch("agent_demo.RPC_URL", "http://localhost:8545"):
                    with patch(
                        "agent_demo.AGENT_PRIVATE_KEY",
                        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
                    ):
                        submit_on_chain(evidence_hash)

        # Verify the correct cast command was built
        mock_run.assert_called_once()
        call_args = mock_run.call_args[0][0]

        assert "cast" in call_args
        assert "send" in call_args
        assert "submitEAL(bytes32,bytes32)" in call_args
        assert "0xdeadbeef12345678" in call_args
        assert evidence_hash in call_args
        assert "--rpc-url" in call_args
        assert "--private-key" in call_args

    @patch("subprocess.run")
    def test_submit_on_chain_failure_exits(self, mock_run, mock_env):
        """Test that failed submission exits with error."""
        from agent_demo import submit_on_chain

        mock_run.return_value = Mock(
            returncode=1, stdout="", stderr="Execution reverted"
        )

        with pytest.raises(SystemExit):
            submit_on_chain("0xbadhash")


class TestCheckEnv:
    """Tests for environment variable validation."""

    def test_missing_env_vars_exits(self):
        """Test that missing required vars causes sys.exit."""
        from agent_demo import check_env, REQUIRED_VARS

        with patch.dict("os.environ", {}, clear=True):
            with pytest.raises(SystemExit):
                check_env()

    def test_all_env_vars_present_passes(self):
        """Test that all required vars present passes."""
        from agent_demo import check_env, REQUIRED_VARS

        env = {var: "test_value" for var in REQUIRED_VARS}
        env["MISSION_ID"] = "0x1234"
        env["ESCROW_CONTRACT"] = "0x5678"
        env["AGENT_PRIVATE_KEY"] = "0xabcd"
        env["GITHUB_REPO"] = "owner/repo"

        with patch.dict("os.environ", env, clear=True):
            # Should not raise
            check_env()


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
