# The command line tool, run as its own program against a store of its own:
# the round trip, the exit codes, growing a store, and what a crash leaves.
# see ARCHITECTURE.md#binding

import os
import subprocess
import time

import pytest

pytestmark = pytest.mark.engine

GiB = 2 ** 30
NAME = "a/c/o"
BODY = b"body " * 1000


def cli(store, *args, stdin=None):
    return subprocess.run(["bluestore-cli", "-d", store, *args], input=stdin, capture_output=True)


def test_round_trip(tmp_path):
    store = str(tmp_path / "store")

    assert cli(store, "put", NAME, '{"v": 1}', stdin=BODY).returncode == 0
    assert cli(store, "-q", "get", NAME).stdout == BODY

    head = cli(store, "head", NAME)
    assert head.returncode == 0
    assert head.stdout == b'{"v": 1}'
    assert b"Timestamp: " in head.stderr

    assert cli(store, "post", NAME, '{"v": 2}').returncode == 0
    assert cli(store, "-q", "head", NAME).stdout == b'{"v": 2}'

    assert cli(store, "delete", NAME, "{}").returncode == 0
    assert b"is deleted" in cli(store, "get", NAME).stderr
    assert cli(store, "list").stdout == b"a/c/o (deleted)\n"
    assert cli(store, "clean").returncode == 0


def test_errors(tmp_path):
    store = str(tmp_path / "store")
    assert cli(store, "put", NAME, "{}", stdin=BODY).returncode == 0

    stale = cli(store, "-t", "1", "put", NAME, "{}", stdin=b"stale")
    assert stale.returncode == 1
    assert b"is not newer than" in stale.stderr

    missing = cli(store, "get", "a/c/missing")
    assert missing.returncode == 1
    assert b"Missing" in missing.stderr

    assert subprocess.run(["bluestore-cli", "--help"], capture_output=True).returncode == 0
    assert subprocess.run(["bluestore-cli", "nonsense"], capture_output=True).returncode == 1
    assert subprocess.run(["bluestore-cli"], capture_output=True).returncode == 1


def test_capacity_grows(tmp_path):
    store = str(tmp_path / "store")
    assert cli(store, "put", NAME, "{}", stdin=BODY).returncode == 0
    assert cli(store, "-c", str(2 * GiB), "-q", "get", NAME).stdout == BODY
    assert os.path.getsize(os.path.join(store, "block")) == 2 * GiB


# A put killed mid-body leaves its object IN_WRITE; clean() removes it.
def test_crash_leftovers_are_cleaned(tmp_path):
    store = str(tmp_path / "store")
    assert cli(store, "list").returncode == 0

    writer = subprocess.Popen(["bluestore-cli", "-d", store, "put", "a/c/crashed", "{}"], stdin=subprocess.PIPE)
    writer.stdin.write(os.urandom(2 * 2 ** 20))
    writer.stdin.flush()
    time.sleep(2)
    writer.kill()
    writer.wait()
    writer.stdin.close()

    listed = cli(store, "list").stdout
    assert b"IN_WRITE a/c/crashed" in listed

    assert cli(store, "clean").returncode == 0
    assert b"a/c/crashed" not in cli(store, "list").stdout
