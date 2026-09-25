# The harness every test runs in: one object server whose policy 0 is Swift's
# own backend and policy 1 is ours, and call(), which sends a request to both
# and compares the responses. Nothing here imports bluestore: the installed
# .pth hook registers our policy, as on a real node, so a hook that did not
# fire fails loudly while swift.conf is parsed.
# see ARCHITECTURE.md#testing

import pytest

_class_failures = {}

def pytest_runtest_makereport(item, call):
    if "incremental" in item.keywords and call.excinfo is not None:
        _class_failures[item.cls] = item.name

def pytest_runtest_setup(item):
    if "incremental" in item.keywords:
        failed = _class_failures.get(item.cls)
        if failed is not None:
            pytest.skip(f"earlier step in sequence failed: {failed}")

from types import SimpleNamespace

import eventlet

from swift.common.utils import closing_if_possible, get_logger
from swift.common import storage_policy, swob, utils
from swift.obj import server as object_server_mod

BLUESTORE_POLICY_TYPE = "bluestore"

SWIFT_CONF_TEMPLATE = """
[swift-hash]
swift_hash_path_suffix = testsuffix
swift_hash_path_prefix = testprefix

[storage-policy:0]
name = default
policy_type = replication
default = yes

[storage-policy:1]
name = bluestore
policy_type = {policy_type}
"""

REFERENCE_POLICY, BLUESTORE_POLICY = 0, 1
TICKS_PER_SECOND = 100_000            # swift timestamps: 10.5 fixed decimal
BLUESTORE_CAPACITY = 2 ** 30          # a store occupies its capacity, so size it

# Only headers that no implementation could make match.
IGNORED_HEADERS = frozenset({
    "Date",                           # wall clock of response generation
})


# Timestamps from an integer counter rather than the clock, so both backends
# see the same ones.
class TickClock:
    def __init__(self, start_second=1_000_000):
        self._ticks = start_second * TICKS_PER_SECOND

    def _fmt(self):
        sec, frac = divmod(self._ticks, TICKS_PER_SECOND)
        return "%010d.%05d" % (sec, frac)

    def next_call(self):
        self._ticks = (self._ticks // TICKS_PER_SECOND + 1) * TICKS_PER_SECOND
        return self._fmt()

    def next_diff(self):
        self._ticks += 1
        return self._fmt()


@pytest.fixture(scope="class")
def swift_conf_dir(tmp_path_factory):
    """Write a custom swift.conf, point swift at it, restore afterwards."""
    conf_dir = tmp_path_factory.mktemp("swift")
    (conf_dir / "swift.conf").write_text(
        SWIFT_CONF_TEMPLATE.format(policy_type=BLUESTORE_POLICY_TYPE))

    saved = (utils.SWIFT_CONF_FILE, utils.HASH_PATH_PREFIX,
             utils.HASH_PATH_SUFFIX, storage_policy._POLICIES)
    utils.set_swift_dir(str(conf_dir))
    storage_policy.reload_storage_policies()

    try:
        yield conf_dir
    finally:
        (utils.SWIFT_CONF_FILE, utils.HASH_PATH_PREFIX,
         utils.HASH_PATH_SUFFIX, storage_policy._POLICIES) = saved


@pytest.fixture(scope="class")
def policies(swift_conf_dir):
    return storage_policy._POLICIES


@pytest.fixture(scope="class")
def object_server(swift_conf_dir, tmp_path_factory):
    """The stock swift ObjectController; backend selection is per-request
    via X-Backend-Storage-Policy-Index."""

    devices = tmp_path_factory.mktemp("devices")
    (devices / "sda1" / "tmp").mkdir(parents=True)

    conf = {
        "devices": str(devices),
        "swift_dir": str(swift_conf_dir),
        "mount_check": "false",
        "bluestore_capacity": str(BLUESTORE_CAPACITY),
        # The settings this backend is deployed with.
        "disk_chunk_size": str(2 ** 20),
        "network_chunk_size": str(2 ** 20),
        "eventlet_tpool_num_threads": "64",
        # The clock starts near 1970, so wall-clock reclaim would collect the
        # reference backend's tombstones mid-run.
        "reclaim_age": str(10**10),      # ~317 years
    }

    logger = get_logger(conf, log_route="object-server", log_to_console=True)
    return object_server_mod.ObjectController(conf, logger=logger)


# A request body that gives up the hub before every read, as a socket would,
# so requests in flight together interleave at chunk boundaries.
class YieldingInput:
    def __init__(self, inner):
        self.inner = inner

    def read(self, size=-1):
        eventlet.sleep(0)
        return self.inner.read(size)


def _assert_identical(r_ref, r_bs, op):
    assert r_ref.status_int == r_bs.status_int, (
        "%s: status default=%s bluestore=%s"
        % (op, r_ref.status, r_bs.status))
    assert r_ref.body == r_bs.body, (
        "%s: bodies differ:\n  default:   %r\n  bluestore: %r"
        % (op, r_ref.body[:200], r_bs.body[:200]))
    strip = lambda r: {k: v for k, v in r.headers.items()
                       if k not in IGNORED_HEADERS}
    assert strip(r_ref) == strip(r_bs), "%s: headers differ" % op


@pytest.fixture(scope="class")
def call(object_server):
    """call(method, path, ...): send to both backends, assert identical
    responses, return the bluestore response.
    call.diff(...): send to bluestore only (intentional divergence).

    Paths are /<device>/<partition>/<account>/<container>/<object>.
    """
    clock = TickClock()

    def _send(method, path, body, headers, timestamp, policy_index):
        hdrs = {
            "X-Timestamp": timestamp,
            "X-Backend-Storage-Policy-Index": str(policy_index),
        }
        if method == "PUT":
            body = body if body is not None else b""
            hdrs["Content-Length"] = str(len(body))
            hdrs.setdefault("Content-Type", "application/octet-stream")
        if headers:
            hdrs.update(headers)
        req = swob.Request.blank(path, method=method, body=body, headers=hdrs)
        req.environ["wsgi.input"] = YieldingInput(req.environ["wsgi.input"])
        resp = req.get_response(object_server)

        length = resp.headers.get("Content-Length")
        chunks = []
        with closing_if_possible(resp.app_iter):
            for chunk in resp.app_iter:
                chunks.append(chunk)
                eventlet.sleep(0)
        resp.body = b"".join(chunks)
        if length is not None:
            resp.headers["Content-Length"] = length
        return resp

    def _call(method, path, body=None, timestamp=None, headers=None):
        t = clock.next_call() if timestamp is None else timestamp
        r_ref = _send(method, path, body, headers, t, REFERENCE_POLICY)
        r_bs = _send(method, path, body, headers, t, BLUESTORE_POLICY)
        _assert_identical(r_ref, r_bs, "%s %s @ %s" % (method, path, t))
        return r_bs

    def _diff(method, path, body=None, timestamp=None, headers=None):
        t = clock.next_diff() if timestamp is None else timestamp
        return _send(method, path, body, headers, t, BLUESTORE_POLICY)

    def _stamps(n):
        return [clock.next_diff() for _ in range(n)]

    def _spawn(method, path, body=None, timestamp=None, headers=None):
        t = clock.next_call() if timestamp is None else timestamp
        r_ref = eventlet.spawn(_send, method, path, body, headers, t, REFERENCE_POLICY)
        r_bs = eventlet.spawn(_send, method, path, body, headers, t, BLUESTORE_POLICY)

        def wait():
            ref, bs = r_ref.wait(), r_bs.wait()
            _assert_identical(ref, bs, "%s %s @ %s" % (method, path, t))
            return bs

        return SimpleNamespace(timestamp=t, wait=wait)

    _call.diff = _diff
    _call.stamps = _stamps
    _call.spawn = _spawn
    return _call
