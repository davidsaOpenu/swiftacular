#!/usr/bin/env python3
"""
Comprehensive tests for bs_xattr utility.

Tests all operations: get, set, list
"""

import subprocess
import tempfile
import os
import pytest


BS_XATTR_PATH = os.environ.get('BS_XATTR_PATH', 'bs_xattr')


def run_bs_xattr(args, check=True):
    """Run bs_xattr command and return result."""
    cmd = [BS_XATTR_PATH] + args
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        check=False
    )
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode, cmd, result.stdout, result.stderr
        )
    return result


class TestBsXattr:
    """Test suite for bs_xattr utility."""

    @pytest.fixture
    def test_file(self):
        """Create a temporary test file."""
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(b"test data for xattr testing")
            test_path = f.name
        yield test_path
        # Cleanup
        try:
            os.unlink(test_path)
            # Also remove the xattr database
            xattr_db = test_path + '.xattr.db'
            if os.path.exists(xattr_db):
                import shutil
                shutil.rmtree(xattr_db)
        except:
            pass

    def test_set_single_xattr(self, test_file):
        """Test setting a single extended attribute."""
        result = run_bs_xattr(['set', test_file, 'user.test_key', 'test_value'])
        assert result.returncode == 0, f"Failed to set xattr: {result.stderr}"

    def test_get_existing_xattr(self, test_file):
        """Test getting an existing extended attribute."""
        # Set an attribute first
        run_bs_xattr(['set', test_file, 'user.mykey', 'myvalue'])

        # Get it back
        result = run_bs_xattr(['get', test_file, 'user.mykey'])
        assert result.returncode == 0, f"Failed to get xattr: {result.stderr}"
        assert 'myvalue' in result.stdout, f"Expected 'myvalue' in output, got: {result.stdout}"

    def test_get_nonexistent_xattr(self, test_file):
        """Test getting a non-existent extended attribute."""
        result = run_bs_xattr(['get', test_file, 'user.nonexistent'], check=False)
        assert result.returncode != 0, "Expected failure for non-existent xattr"

    def test_set_multiple_xattrs(self, test_file):
        """Test setting multiple extended attributes."""
        attrs = {
            'user.attr1': 'value1',
            'user.attr2': 'value2',
            'user.attr3': 'value3',
        }

        for key, value in attrs.items():
            result = run_bs_xattr(['set', test_file, key, value])
            assert result.returncode == 0, f"Failed to set {key}: {result.stderr}"

        # Verify all attributes
        for key, expected_value in attrs.items():
            result = run_bs_xattr(['get', test_file, key])
            assert result.returncode == 0, f"Failed to get {key}: {result.stderr}"
            assert expected_value in result.stdout, f"Expected '{expected_value}' for {key}"

    def test_list_xattrs(self, test_file):
        """Test listing all extended attributes."""
        # Set some attributes
        run_bs_xattr(['set', test_file, 'user.key1', 'val1'])
        run_bs_xattr(['set', test_file, 'user.key2', 'val2'])
        run_bs_xattr(['set', test_file, 'user.key3', 'val3'])

        # List all attributes
        result = run_bs_xattr(['list', test_file])
        assert result.returncode == 0, f"Failed to list xattrs: {result.stderr}"

        # Check that all keys are present
        for key in ['user.key1', 'user.key2', 'user.key3']:
            assert key in result.stdout, f"Expected {key} in list output"

    def test_list_empty_xattrs(self, test_file):
        """Test listing extended attributes when none are set."""
        result = run_bs_xattr(['list', test_file])
        # Should succeed but return empty or minimal output
        assert result.returncode == 0, f"Failed to list empty xattrs: {result.stderr}"

    def test_update_existing_xattr(self, test_file):
        """Test updating an existing extended attribute."""
        key = 'user.updatetest'

        # Set initial value
        run_bs_xattr(['set', test_file, key, 'initial_value'])
        result = run_bs_xattr(['get', test_file, key])
        assert 'initial_value' in result.stdout

        # Update with new value
        run_bs_xattr(['set', test_file, key, 'updated_value'])
        result = run_bs_xattr(['get', test_file, key])
        assert 'updated_value' in result.stdout
        assert 'initial_value' not in result.stdout

    def test_xattr_with_special_characters(self, test_file):
        """Test extended attributes with special characters in values."""
        special_values = [
            'value with spaces',
            'value-with-dashes',
            'value_with_underscores',
            'value.with.dots',
            'value/with/slashes',
        ]

        for i, value in enumerate(special_values):
            key = f'user.special{i}'
            result = run_bs_xattr(['set', test_file, key, value])
            assert result.returncode == 0, f"Failed to set {key} with value '{value}'"

            # Verify we can get it back
            result = run_bs_xattr(['get', test_file, key])
            assert result.returncode == 0, f"Failed to get {key}"

    def test_xattr_with_long_value(self, test_file):
        """Test extended attributes with long values."""
        long_value = 'x' * 1024  # 1KB value
        key = 'user.longvalue'

        result = run_bs_xattr(['set', test_file, key, long_value])
        assert result.returncode == 0, "Failed to set long value"

        result = run_bs_xattr(['get', test_file, key])
        assert result.returncode == 0, "Failed to get long value"
        assert long_value in result.stdout or len(result.stdout.strip()) == len(long_value)

    def test_xattr_on_nonexistent_file(self):
        """Test operations on non-existent file."""
        nonexistent = '/tmp/bs_xattr_nonexistent_file_test'

        # Get should fail
        result = run_bs_xattr(['get', nonexistent, 'user.test'], check=False)
        assert result.returncode != 0, "Expected failure for non-existent file"

        # Set should work (creates database)
        result = run_bs_xattr(['set', nonexistent, 'user.test', 'value'])
        assert result.returncode == 0, "Set should succeed even for non-existent file"

        # Cleanup
        try:
            xattr_db = nonexistent + '.xattr.db'
            if os.path.exists(xattr_db):
                import shutil
                shutil.rmtree(xattr_db)
        except:
            pass

    def test_invalid_arguments(self):
        """Test bs_xattr with invalid arguments."""
        # No arguments
        result = run_bs_xattr([], check=False)
        assert result.returncode != 0, "Expected failure with no arguments"

        # Invalid command
        result = run_bs_xattr(['invalid_command', '/tmp/test'], check=False)
        assert result.returncode != 0, "Expected failure with invalid command"

        # Missing arguments for get
        result = run_bs_xattr(['get', '/tmp/test'], check=False)
        assert result.returncode != 0, "Expected failure with missing key for get"

        # set without value reads from stdin (empty stdin = empty value, which succeeds)
        # This is intentional behavior for binary data support
        result = run_bs_xattr(['set', '/tmp/test', 'key'], check=False)
        assert result.returncode == 0, "set with empty stdin should succeed (stores empty value)"


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
