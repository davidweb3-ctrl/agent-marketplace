#!/usr/bin/env python3
"""Tests for github_bot.py - GitHub issue processing and TDL YAML parsing."""

import pytest
from unittest.mock import Mock, MagicMock, patch
import sys


class MockIssue:
    """Mock GitHub Issue object."""

    def __init__(self, number, title, body, labels=None, comments=None):
        self.number = number
        self.title = title
        self.body = body
        self.labels = labels or []
        self._comments = comments or []
        self.pull_request = None

    def get_comments(self):
        return iter(self._comments)

    def create_comment(self, body):
        self._comments.append(body)


class MockComment:
    """Mock GitHub Comment object."""

    def __init__(self, body):
        self.body = body


class MockLabel:
    """Mock GitHub Label object."""

    def __init__(self, name):
        self.name = name


@pytest.fixture
def mock_gh():
    """Mock PyGithub client."""
    return Mock()


@pytest.fixture
def mock_repo(mock_gh):
    """Mock GitHub repository."""
    repo = Mock()
    mock_gh.get_repo.return_value = repo
    return repo


class TestParseTDLYaml:
    """Tests for parse_tdl_yaml function."""

    def test_parse_tdl_block_format(self):
        """Test parsing TDL from fenced code block."""
        from github_bot import parse_tdl_yaml

        issue_body = """
## Task Description

Please implement feature X.

```tdl
mission_id: 0x1234
agent: 0xabcd
reward: 1000000
duration_minutes: 60
```
"""
        result = parse_tdl_yaml(issue_body)

        assert result is not None
        assert result["mission_id"] == "0x1234"
        assert result["agent"] == "0xabcd"
        assert result["reward"] == 1000000
        assert result["duration_minutes"] == 60

    def test_parse_tdl_inline_format(self):
        """Test parsing TDL from inline format."""
        from github_bot import parse_tdl_yaml

        issue_body = """
## Task Description

tdl: |
  mission_id: 0x5678
  agent: 0xdef0
  reward: 500000
  duration_minutes: 30
"""
        result = parse_tdl_yaml(issue_body)

        assert result is not None
        assert result["mission_id"] == "0x5678"
        assert result["reward"] == 500000

    def test_parse_tdl_no_block(self):
        """Test that missing TDL block returns None."""
        from github_bot import parse_tdl_yaml

        issue_body = "## Task Description\n\nJust a regular issue."

        result = parse_tdl_yaml(issue_body)

        assert result is None

    def test_parse_tdl_invalid_yaml(self):
        """Test that invalid YAML logs error and returns None."""
        from github_bot import parse_tdl_yaml

        issue_body = """
```tdl
mission_id: 0x1234
  invalid yaml: - this: is
    broken:
```
"""
        result = parse_tdl_yaml(issue_body)

        assert result is None


class TestProcessIssue:
    """Tests for process_issue function."""

    @patch("github_bot.create_mission_on_chain")
    @patch("github_bot.post_comment")
    def test_issue_with_valid_tdl_label_agent_task(self, mock_post, mock_create):
        """Test: issue with valid TDL and label 'agent-task' creates mission."""
        from github_bot import process_issue

        # Setup: Issue with agent-task label and valid TDL
        issue_body = """
```tdl
mission_id: 0xdeadbeef
agent: 0x1234567890123456789012345678901234567890
reward: 1000000
duration_minutes: 60
```
"""
        mock_issue = MockIssue(
            number=1,
            title="Implement feature X",
            body=issue_body,
            labels=[MockLabel("agent-task")],
            comments=[],
        )
        mock_create.return_value = "0xtxhash123"

        # Execute
        process_issue(mock_issue)

        # Verify mission was created on-chain
        mock_create.assert_called_once_with(
            "0xdeadbeef", "0x1234567890123456789012345678901234567890", 1000000, 60
        )
        # Verify comment was posted
        mock_post.assert_called_once_with(mock_issue, "0xtxhash123")

    @patch("github_bot.create_mission_on_chain")
    @patch("github_bot.post_comment")
    def test_issue_without_label_ignored(self, mock_post, mock_create):
        """Test: issue without 'agent-task' label is ignored."""
        from github_bot import process_issue

        issue_body = """
```tdl
mission_id: 0x1234
reward: 1000000
```
"""
        mock_issue = MockIssue(
            number=2,
            title="Regular issue",
            body=issue_body,
            labels=[MockLabel("bug")],  # Wrong label
            comments=[],
        )

        # Execute
        process_issue(mock_issue)

        # Verify nothing happened
        mock_create.assert_not_called()
        mock_post.assert_not_called()

    @patch("github_bot.create_mission_on_chain")
    @patch("github_bot.post_comment")
    def test_issue_with_invalid_yaml_no_mission(self, mock_post, mock_create):
        """Test: issue with invalid YAML logs error, no mission created."""
        from github_bot import process_issue

        issue_body = """
```tdl
mission_id: 0x1234
  invalid: yaml: - content:
```
"""
        mock_issue = MockIssue(
            number=3,
            title="Issue with bad YAML",
            body=issue_body,
            labels=[MockLabel("agent-task")],
            comments=[],
        )

        # Execute
        process_issue(mock_issue)

        # Verify no mission was created
        mock_create.assert_not_called()
        mock_post.assert_not_called()

    @patch("github_bot.create_mission_on_chain")
    @patch("github_bot.post_comment")
    def test_duplicate_issue_skipped(self, mock_post, mock_create):
        """Test: duplicate issue (already processed) is skipped."""
        from github_bot import process_issue

        issue_body = """
```tdl
mission_id: 0xabcd
reward: 500000
```
"""
        # Issue already has a comment indicating it's processed
        existing_comment = MockComment("⚡ Mission created on-chain: 0xtxhash")
        mock_issue = MockIssue(
            number=4,
            title="Duplicate issue",
            body=issue_body,
            labels=[MockLabel("agent-task")],
            comments=[existing_comment],
        )

        # Execute
        process_issue(mock_issue)

        # Verify nothing happened (already processed)
        mock_create.assert_not_called()
        mock_post.assert_not_called()


class TestCheckEnv:
    """Tests for environment variable validation."""

    def test_missing_env_vars_exits(self):
        """Test that missing required vars causes sys.exit."""
        from github_bot import check_env, REQUIRED_VARS

        with patch.dict("os.environ", {}, clear=True):
            with pytest.raises(SystemExit):
                check_env()

    def test_all_env_vars_present_passes(self):
        """Test that all required vars present passes."""
        from github_bot import check_env, REQUIRED_VARS

        env = {var: "test_value" for var in REQUIRED_VARS}
        with patch.dict("os.environ", env, clear=True):
            # Should not raise
            check_env()


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
