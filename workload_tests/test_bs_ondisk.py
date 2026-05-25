#!/usr/bin/env python3
"""
Basic tests for bs_ondisk utility - command-line interface validation.

Note: Full integration tests require a properly initialized BlueStore instance.
The main Swift workload tests validate end-to-end BlueStore functionality.
These tests focus on command-line argument handling and basic utility behavior.
"""

import subprocess
import os
import pytest


BS_ONDISK_PATH = os.environ.get('BS_ONDISK_PATH', 'bs_ondisk')


def run_bs_ondisk(args, stdin_data=None, check=True):
    """Run bs_ondisk command and return result."""
    cmd = [BS_ONDISK_PATH] + args
    result = subprocess.run(
        cmd,
        input=stdin_data,
        capture_output=True,
        text=False if stdin_data else True,
        check=False
    )
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode, cmd, result.stdout, result.stderr
        )
    return result


class TestBsOndiskCLI:
    """Test suite for bs_ondisk command-line interface."""

    def test_no_arguments(self):
        """Test bs_ondisk with no arguments shows usage."""
        result = run_bs_ondisk([], check=False)
        assert result.returncode != 0, "Expected failure with no arguments"
        # Should show usage message
        output = result.stdout + result.stderr
        assert 'Usage:' in output or 'usage:' in output.lower()

    def test_invalid_command(self):
        """Test bs_ondisk with invalid command."""
        result = run_bs_ondisk(['invalid_command', '/tmp/test'], check=False)
        assert result.returncode != 0, "Expected failure with invalid command"

    def test_list_missing_path(self):
        """Test list command without path argument."""
        result = run_bs_ondisk(['list'], check=False)
        assert result.returncode != 0, "Expected failure when path is missing"

    def test_list_nonexistent_path(self):
        """Test list command with non-existent BlueStore path."""
        nonexistent = '/nonexistent/bluestore/path/test123456'
        result = run_bs_ondisk(['list', nonexistent], check=False)
        assert result.returncode != 0, "Expected failure for non-existent path"

    def test_verify_missing_arguments(self):
        """Test verify command without required arguments."""
        result = run_bs_ondisk(['verify'], check=False)
        assert result.returncode != 0, "Expected failure with missing arguments"

        result = run_bs_ondisk(['verify', '/tmp/test'], check=False)
        assert result.returncode != 0, "Expected failure with missing object name"

    def test_verify_nonexistent_object(self):
        """Test verify command for non-existent object."""
        result = run_bs_ondisk(['verify', '/tmp/nonexistent', 'obj.data'], check=False)
        assert result.returncode != 0, "Expected failure for non-existent object"

    def test_stat_missing_arguments(self):
        """Test stat command without required arguments."""
        result = run_bs_ondisk(['stat'], check=False)
        assert result.returncode != 0, "Expected failure with missing arguments"

        result = run_bs_ondisk(['stat', '/tmp/test'], check=False)
        assert result.returncode != 0, "Expected failure with missing object name"

    def test_read_missing_arguments(self):
        """Test read command without required arguments."""
        result = run_bs_ondisk(['read'], check=False)
        assert result.returncode != 0, "Expected failure with missing arguments"

        result = run_bs_ondisk(['read', '/tmp/test'], check=False)
        assert result.returncode != 0, "Expected failure with missing object name"

    def test_write_missing_arguments(self):
        """Test write command without required arguments."""
        result = run_bs_ondisk(['write'], check=False)
        assert result.returncode != 0, "Expected failure with missing arguments"

        result = run_bs_ondisk(['write', '/tmp/test'], check=False)
        assert result.returncode != 0, "Expected failure with missing object name"

        result = run_bs_ondisk(['write', '/tmp/test', 'obj.data'], check=False)
        assert result.returncode != 0, "Expected failure with missing size"

    def test_remove_missing_arguments(self):
        """Test remove command without required arguments."""
        result = run_bs_ondisk(['remove'], check=False)
        assert result.returncode != 0, "Expected failure with missing arguments"

        result = run_bs_ondisk(['remove', '/tmp/test'], check=False)
        assert result.returncode != 0, "Expected failure with missing object name"

    def test_help_output(self):
        """Test that bs_ondisk provides usage information."""
        # Most utilities show help with no args or return error
        result = run_bs_ondisk([], check=False)

        # Check that we get some output (either stdout or stderr)
        assert result.stdout or result.stderr, "Expected some output from bs_ondisk"

        output = (result.stdout if result.stdout else "") + (result.stderr if result.stderr else "")
        # Should mention at least one command or "usage"
        assert any(word in output.lower() for word in ['usage', 'command', 'list', 'read', 'write']), \
            "Expected usage information in output"


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
