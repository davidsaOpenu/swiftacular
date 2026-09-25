# Times the same work through the binding and through the command line tool.
# Not in the default run; ask for it with -m fork.
# see ARCHITECTURE.md#testing

import subprocess
import time
import gc

import pytest

from bluestore._raw import Backend

OBJECT_NAME = "AAAA/BBBB/CCCC"
OBJECT_SIZE = 2 ** 20
OBJECT_BODY = b"A" * OBJECT_SIZE
OBJECT_META = '{"Content-Type": "text/plain"}'

ITERATIONS_BIND = 10000
ITERATIONS_FORK = 1000

def measure(iterations, ret=None):
    def wrap_a(fn):
        def wrap_b(*args, **kwargs):
            start = time.perf_counter()

            for i in range(iterations):
                assert fn(*args, **kwargs) == ret

            total = time.perf_counter() - start
            return total, total / iterations
        return wrap_b
    return wrap_a


@measure(ITERATIONS_FORK)
def fork_put(store):
    result = subprocess.run(
        ["bluestore-cli", "-q", "-d", store, "put", OBJECT_NAME, OBJECT_META],
        input=OBJECT_BODY,
        capture_output=True,
        check=False
    )

    if result.returncode != 0:
        raise ValueError(result.stderr)


@measure(ITERATIONS_FORK, OBJECT_BODY)
def fork_get(store):
    result = subprocess.run(
        ["bluestore-cli", "-q", "-d", store, "get", OBJECT_NAME],
        capture_output=True,
        check=False
    )

    if result.returncode != 0:
        raise ValueError(result.stderr)

    return result.stdout


@measure(ITERATIONS_BIND)
def bind_put(back):
    prev = back.find(OBJECT_NAME)
    prev.open()

    obj = back.create(OBJECT_NAME)
    obj.write(OBJECT_BODY)
    obj.write_metadata(OBJECT_META.encode())

    back.put(obj, prev)
    obj.sync()


@measure(ITERATIONS_BIND, OBJECT_BODY)
def bind_get(back):
    obj = back.find(OBJECT_NAME)
    obj.open()

    return obj.read(0, OBJECT_SIZE)


@pytest.mark.fork
def test_fork(tmp_path):
    store = str(tmp_path / "store")

    back = Backend(store)
    print("Store warmed up")

    bind_put_total, bind_put_one = bind_put(back)
    print(f"{bind_put_total=}s")
    print(f"{bind_put_one=}s")

    bind_get_total, bind_get_one = bind_get(back)
    print(f"{bind_get_total=}s")
    print(f"{bind_get_one=}s")

    del back
    gc.collect()

    fork_put_total, fork_put_one = fork_put(store)
    print(f"{fork_put_total=}s")
    print(f"{fork_put_one=}s")

    fork_get_total, fork_get_one = fork_get(store)
    print(f"{fork_get_total=}s")
    print(f"{fork_get_one=}s")

    assert bind_put_one *  5 < fork_put_one
    assert bind_get_one * 10 < fork_get_one
