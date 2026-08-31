# Times the same work through the binding and through the command line tool.
# Not in the default run; ask for it with -m fork.
# see DESIGN.md#testing

import subprocess
import time

import pytest

from bluestore._raw import Backend

ITERATIONS = 10_000


def fork_fake_read(file, size=512):
    result = subprocess.run(
        ["bluestore-cli", "-m", "fake_read", file, str(size)],
        capture_output=True,
        check=False
    )

    if result.returncode != 0:
        raise ValueError(result.stderr)

    return result.stdout


def fork_fake_write(file, data):
    result = subprocess.run(
        ["bluestore-cli", "-m", "fake_write", file],
        input=data,
        capture_output=True,
        check=False
    )

    if result.returncode != 0:
        raise ValueError(result.stderr)

    return int(result.stdout)


def duration_of(fn, *args, ret=None, **kwargs):
    start = time.perf_counter()

    for i in range(ITERATIONS):
        assert fn(*args, **kwargs) == ret

    return time.perf_counter() - start


@pytest.mark.fork
def test_fork():
    back = Backend("fake")

    size = 2 ** 20 # 1 Mib
    body = b"A" * size
    file = "object"


    bind_read = duration_of(back.fake_read, file, size, ret=body)
    print(f"{bind_read=}s")

    fork_read = duration_of(fork_fake_read, file, size, ret=body)
    print(f"{fork_read=}s")

    assert bind_read * 10 < fork_read

    bind_write = duration_of(back.fake_write, file, body, ret=size)
    print(f"{bind_write=}s")

    fork_write = duration_of(fork_fake_write, file, body, ret=size)
    print(f"{fork_write=}s")

    assert bind_write * 5 < fork_write
