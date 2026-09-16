# conftest.py
#
# Harness for in-process differential testing of the stock swift object
# server against two backends selected purely by storage policy:
#   policy 0 -> standard posix DiskFileManager (the reference)
#   policy 1 -> bluestore DiskFileManager
#
# Design:
#   * No bluestore import here. Registration of the policy type and its
#     DiskFileManager is the job of the installed .pth hook, exactly as on a
#     real swift node. If the hook did not fire, swift.conf parsing fails at
#     'policy_type = bluestore' -- which is the correct, loud failure.
#   * call(...)  sends every request to BOTH backends with an identical
#     timestamp, asserts the responses are identical (status, body, headers),
#     and returns the bluestore response. Unintentional divergence therefore
#     fails by default, including on error responses.
#   * call.diff(...) sends to bluestore only, for intentionally divergent
#     behavior. Grep for '.diff(' to inventory all known divergence.
#   * Timestamps: call() advances to the next whole-second boundary;
#     call.diff() advances one swift tick (1e-5 s). call()'s timestamp grid
#     is therefore invariant to interleaved diff calls, keeping the two
#     backend states in lockstep. Integer tick arithmetic; no float drift.
#   * Fixtures are class-scoped: a test class is a deliberate sequence
#     operating on shared server state, in method definition order.

import pytest

_class_failures = {}

def pytest_runtest_makereport(item, call):
    # Class-scoped: a test class is one scenario carried out step by step against shared state.
    # see ARCHITECTURE.md#testing
    if "incremental" in item.keywords and call.excinfo is not None:
        _class_failures[item.cls] = item.name

def pytest_runtest_setup(item):
    if "incremental" in item.keywords:
        failed = _class_failures.get(item.cls)
        if failed is not None:
            pytest.skip(f"earlier step in sequence failed: {failed}")

from swift.common.utils import get_logger
from swift.common import storage_policy, swob, utils
from swift.obj import server as object_server_mod

BLUESTORE_POLICY_TYPE = "bluestore"   # policy_type string in swift.conf

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
# see ARCHITECTURE.md#testing
IGNORED_HEADERS = frozenset({
    "Date",                           # wall clock of response generation
})


# Both backends must see identical timestamps, so these come from an integer counter rather than the clock.
# Comparison calls step a whole second and single-backend calls one tick,
# so inserting the latter never shifts the former.
# see ARCHITECTURE.md#testing
class TickClock:
    """Integer-tick timestamp source. call() -> next second boundary;
    diff() -> +1 tick, never crossing into the next boundary's territory."""

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
        # test timestamps are epoch-1970-era; disable wall-clock tombstone
        # reclaim so the posix reference keeps its tombstones (see TickClock).
        # The tick clock starts near the epoch,
        # so wall-clock reclamation would collect the reference backend's tombstones mid-run.
        # see ARCHITECTURE.md#testing
        "reclaim_age": str(10**10),      # ~317 years
    }

    logger = get_logger(conf, log_route="object-server", log_to_console=True)
    return object_server_mod.ObjectController(conf, logger=logger)


# Every request goes to both backends and the responses are compared in full.
# Anything that differs fails, including error responses.
# see ARCHITECTURE.md#testing
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
        return req.get_response(object_server)

    def _call(method, path, body=None, headers=None, timestamp=None):
        t = clock.next_call() if timestamp is None else timestamp
        r_ref = _send(method, path, body, headers, t, REFERENCE_POLICY)
        r_bs = _send(method, path, body, headers, t, BLUESTORE_POLICY)
        _assert_identical(r_ref, r_bs, "%s %s @ %s" % (method, path, t))
        return r_bs

    # Our backend only, for intentional divergence. Each use is a claim that a difference is correct;
    # the set of uses is the record of where the backends part ways.
    # see ARCHITECTURE.md#testing
    def _diff(method, path, body=None, headers=None, timestamp=None):
        t = clock.next_diff() if timestamp is None else timestamp
        return _send(method, path, body, headers, t, BLUESTORE_POLICY)

    _call.diff = _diff
    return _call
