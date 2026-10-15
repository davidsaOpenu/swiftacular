"""Read-only observation helper for Swiftacular probe tests.

Observer reports account and container data through the public Swift API and
uses direct, read-only requests to inspect sharding state on container-server
primaries. It reports shard ranges, cleaving progress, and object distribution
without creating resources, changing configuration, or managing services.

Replica consistency is outside its scope. Each combined snapshot pins all
backend observations to one responsive primary and reports that primary so
callers can identify the replica that supplied the data.
"""

import time
import warnings
from collections import Counter
from urllib.parse import parse_qsl

from swift.common import direct_client
from swift.common.utils import ShardRange
from swiftclient import client as swift_client


class ObserverError(RuntimeError):
    # Base error raised by Observer.
    pass


class ObserverBackendError(ObserverError):
    # Raised when all container replicas fail an observation.
    pass


class Observer:

    SHARDING_PHASE_UNSHARDED = "unsharded"
    SHARDING_PHASE_STARTED = "sharding"
    SHARDING_PHASE_UNKNOWN = "unknown"


    # Save connection details; timeout values are measured in seconds.
    def __init__(
        self, url, token, account,
        container_ring=None,
        conn_timeout=5.0,
        response_timeout=15.0,
    ):
        self.url = url
        self.token = token
        self.account = account
        self.container_ring = container_ring

        self.conn_timeout = conn_timeout
        self.response_timeout = response_timeout


    # ------------------------------------------------------------------
    # External / proxy-visible observations
    # Information that any user can inspect by using the proxy
    # ------------------------------------------------------------------

    # Return all container names visible under the authenticated account.
    def get_containers(self):
        _headers, containers = swift_client.get_account(
            self.url, self.token, full_listing=True
        )

        return [entry["name"] for entry in containers]

    # Return one container's proxy-visible object count.
    def get_container_object_count(self, containerName):
        headers = swift_client.head_container(self.url, self.token, containerName)

        value = self._get_header(headers, "x-container-object-count")

        if value is None:
            raise ObserverError(
                "Container " + repr(containerName) + " HEAD response did not contain "
                "'X-Container-Object-Count'"
            )

        return int(value)

    # Return proxy-visible object counts for all account containers.
    def get_container_object_counts(self):
        _headers, containers = swift_client.get_account(
            self.url, self.token, full_listing=True
        )
        result = {}

        for entry in containers:
            result[entry["name"]] = int(entry.get("count", 0))

        return result

    # Return every proxy-visible object in a container.
    def get_container_objects(self, containerName):
        # full_listing = True is needed, normal Swift listings are limited
        _headers, objects = swift_client.get_container(
            self.url, self.token, containerName, full_listing=True
        )

        return [dict(obj) for obj in objects]

    # Return one container's proxy-visible object and byte counts.
    def get_container_stats(self, containerName):
        headers = swift_client.head_container(self.url, self.token, containerName)

        return {
            "name": containerName,
            "object_count": self._header_as_int(
                headers,
                "x-container-object-count",
                default=0,
            ),
            "bytes_used": self._header_as_int(
                headers,
                "x-container-bytes-used",
                default=0,
            ),
        }

    # Return a proxy-visible snapshot of the account.
    def get_account_snapshot(self):
        # Only get external data using the proxy.
        account_headers, containers = swift_client.get_account(
            self.url, self.token, full_listing=True
        )

        normalized_containers = []

        for entry in containers:
            normalized_containers.append(
                {
                    "name": entry["name"],
                    "object_count": int(entry.get("count", 0)),
                    "bytes_used": int(entry.get("bytes", 0)),
                }
            )

        return {
            "account": self.account,
            "container_count": self._header_as_int(
                account_headers,
                "x-account-container-count",
                default=len(normalized_containers),
            ),
            "object_count": self._header_as_int(
                account_headers,
                "x-account-object-count",
                default=sum(
                    item["object_count"]
                    for item in normalized_containers
                ),
            ),
            "bytes_used": self._header_as_int(
                account_headers,
                "x-account-bytes-used",
                default=sum(
                    item["bytes_used"]
                    for item in normalized_containers
                ),
            ),
            "containers": normalized_containers,
        }

    # ------------------------------------------------------------------
    # Internal / backend observations
    # Use direct calls to inspect information unavailable through the proxy.
    # ------------------------------------------------------------------

    # Return the root container's backend sharding state.
    def get_internal_sharding_state(self, containerName, primary=None):

        # Read the container HEAD from one primary node.
        def head_primary(node, partition):
            return direct_client.direct_head_container(
                node,
                partition,
                self.account,
                containerName,
                conn_timeout=self.conn_timeout,
                response_timeout=self.response_timeout,
            )

        headers = self._run_on_primary(
            containerName, head_primary, primary=primary
        )

        state = self._get_header(headers, "x-backend-sharding-state")

        if state is None:
            return None

        return str(state).lower()

    # Map the state to unsharded, sharding, or unknown.
    def classify_sharding_state(self, state):
        if state == "unsharded":
            return self.SHARDING_PHASE_UNSHARDED
        if state in {"sharding", "sharded"}:
            return self.SHARDING_PHASE_STARTED
        return self.SHARDING_PHASE_UNKNOWN

    # Return the root container's own shard range.
    def get_internal_own_shard_range(self, containerName, primary=None):
        shard_ranges = self._get_backend_shard_listing(
            containerName,
            query_string="states=auditing",
            primary=primary,
        )

        own_name = self.account + "/" + containerName

        for shard_range in shard_ranges:
            if shard_range.get("name") == own_name:
                return self._format_shard_range(shard_range)

        return None

    # Return all shard ranges, excluding the root range.
    def get_internal_shard_ranges(
        self, containerName, include_deleted=False, primary=None
    ):
        headers = {
            "X-Backend-Record-Type": "shard",
            "X-Backend-Record-Shard-Format": "full",
        }

        if include_deleted:
            headers["X-Backend-Include-Deleted"] = "true"

        shard_ranges = self._get_backend_shard_listing(
            containerName,
            headers=headers,
            primary=primary,
        )

        own_name = self.account + "/" + containerName

        result = []

        for shard_range in shard_ranges:
            if shard_range.get("name") == own_name:
                continue

            formatted = self._format_shard_range(shard_range)

            if not include_deleted and formatted["deleted"]:
                continue

            result.append(formatted)

        return result

    # Return the number of non-deleted shard ranges.
    def get_internal_shard_count(self, containerName):
        return len(self.get_internal_shard_ranges(containerName))

    # Count shard ranges by state.
    def get_internal_shard_summary(self, containerName):
        shard_ranges = self.get_internal_shard_ranges(containerName)

        counts = Counter(shard_range["state"] for shard_range in shard_ranges)

        result = {
            "total": len(shard_ranges),
        }

        for state_name in self._known_shard_state_names():
            result[state_name] = counts.get(state_name, 0)

        for state_name, count in counts.items():
            result.setdefault(state_name, count)

        return result

    # Derive cleaving progress from shard-range states.
    def get_internal_cleaving_progress(self, containerName):
        shard_ranges = self.get_internal_shard_ranges(containerName)

        completed_states = {
            "cleaved",
            "active",
            "shrinking",
            "sharding",
            "sharded",
            "shrunk",
        }

        ranges_done = sum(
            1
            for shard_range in shard_ranges
            if shard_range["state"] in completed_states
        )

        total = len(shard_ranges)
        ranges_todo = total - ranges_done

        return {
            "ranges_done": ranges_done,
            "ranges_todo": ranges_todo,
            "cleaving_done": bool(total) and ranges_todo == 0,
            "source": "derived_from_shard_states",
        }

    # Return object counts and state for every shard range.
    def get_internal_shard_distribution(self, containerName):
        shard_ranges = self.get_internal_shard_ranges(containerName)

        distribution = []
        for index, shard_range in enumerate(shard_ranges, start=1):
            distribution.append(
                {
                    "index": index,
                    "name": shard_range["name"],
                    "range": dict(shard_range["range"]),
                    "object_count": shard_range["object_count"],
                    "bytes_used": shard_range["bytes_used"],
                    "state": shard_range["state"],
                }
            )

        return distribution

    # ------------------------------------------------------------------
    # Combined observations
    # Observations that might use both the proxy and direct calls as a source
    # ------------------------------------------------------------------

    # Return proxy and backend state for one container.
    def get_container_snapshot(self, containerName):
        snapshot = self.get_container_stats(containerName)

        if self.container_ring is None:
            snapshot.update(
                {
                    "backend_available": False,
                    "backend_primary": None,
                    "sharding_state": None,
                    "sharding_phase": self.SHARDING_PHASE_UNKNOWN,
                    "is_sharded": None,
                    "own_shard_range": None,
                    "shard_count": None,
                    "shard_summary": None,
                    "cleaving_progress": None,
                    "shards": None,
                    "shard_metadata_count": None,
                }
            )
            return snapshot

        partition, nodes = self._get_primary_nodes(containerName)
        failures = []

        for node in nodes:
            primary = (partition, node)

            try:
                sharding_state = self.get_internal_sharding_state(
                    containerName, primary=primary
                )
                own_shard_range = self.get_internal_own_shard_range(
                    containerName, primary=primary
                )
                shard_ranges = self.get_internal_shard_ranges(
                    containerName, primary=primary
                )
                break
            except Exception as exc:
                failures.append(self._primary_failure(node, exc))
        else:
            raise self._all_primaries_failed(
                containerName, partition, failures
            )

        warnings.warn(
            "Observer snapshots use one responsive primary and do not verify "
            "replica consistency.",
            RuntimeWarning,
            stacklevel=2,
        )

        # Avoid performing several duplicate backend GETs while building
        # the aggregate snapshot.
        shard_summary = self._summarize_shard_ranges(shard_ranges)
        cleaving_progress = self._derive_cleaving_progress(shard_ranges)
        distribution = self._distribution_from_ranges(shard_ranges)

        snapshot.update(
            {
                "backend_available": True,
                "backend_primary": self._format_primary(node, partition),
                "sharding_state": sharding_state,
                "sharding_phase": self.classify_sharding_state(sharding_state),
                "is_sharded": sharding_state == "sharded",
                "own_shard_range": own_shard_range,
                "shard_count": len(shard_ranges),
                "shard_summary": shard_summary,
                "cleaving_progress": cleaving_progress,
                "shards": distribution,
                "shard_metadata_count": sum(
                    shard["object_count"] for shard in distribution
                ),
            }
        )

        return snapshot

    def wait_until_stable(
        self,
        containerName,
        timeout=300.0,
        poll_interval=5.0,
    ):
        """Wait until a container reaches a stable sharding state."""
        if timeout < 0 or poll_interval <= 0:
            raise ValueError("timeout must be non-negative and poll_interval positive")

        started = time.monotonic()
        deadline = started + timeout
        last_snapshot = None

        while True:
            last_snapshot = self.get_container_snapshot(containerName)
            state = last_snapshot.get("sharding_state")
            progress = last_snapshot.get("cleaving_progress") or {}
            stable = state == self.SHARDING_PHASE_UNSHARDED or (
                state == "sharded" and progress.get("cleaving_done") is True
            )
            if stable:
                last_snapshot["elapsed"] = time.monotonic() - started
                last_snapshot["timed_out"] = False
                return last_snapshot

            now = time.monotonic()
            if now >= deadline:
                last_snapshot["elapsed"] = now - started
                last_snapshot["timed_out"] = True
                raise ObserverError(
                    "Container %r did not become stable before timeout: %r"
                    % (containerName, last_snapshot)
                )
            time.sleep(min(poll_interval, deadline - now))

    def wait_until_expected_count(
        self,
        containerName,
        expected_count,
        timeout=300.0,
        poll_interval=5.0,
    ):
        """Wait until the proxy-visible object count reaches expected_count."""
        if expected_count < 0:
            raise ValueError("expected_count must be non-negative")
        if timeout < 0 or poll_interval <= 0:
            raise ValueError("timeout must be non-negative and poll_interval positive")

        started = time.monotonic()
        deadline = started + timeout
        last_snapshot = None

        while True:
            last_snapshot = self.get_container_snapshot(containerName)
            if last_snapshot.get("object_count", 0) >= expected_count:
                last_snapshot["elapsed"] = time.monotonic() - started
                last_snapshot["expected_object_count"] = expected_count
                last_snapshot["timed_out"] = False
                return last_snapshot

            now = time.monotonic()
            if now >= deadline:
                last_snapshot["elapsed"] = now - started
                last_snapshot["expected_object_count"] = expected_count
                last_snapshot["timed_out"] = True
                raise ObserverError(
                    "Container %r did not reach object count %d before timeout: %r"
                    % (containerName, expected_count, last_snapshot)
                )
            time.sleep(min(poll_interval, deadline - now))

    # ------------------------------------------------------------------
    # Internal helper functions
    # ------------------------------------------------------------------

    # Verify a ring is available before performing backend observations.
    def _require_container_ring(self):
        if self.container_ring is None:
            raise ObserverError(
                "Internal observation requires a container_ring"
            )

    # Locate the primary container nodes and partition.
    def _get_primary_nodes(self, containerName):
        self._require_container_ring()

        partition, nodes = self.container_ring.get_nodes(
            self.account, containerName
        )

        if not nodes:
            raise ObserverBackendError(
                "Container ring returned no primary nodes for "
                + self.account + "/" + containerName
            )

        return partition, list(nodes)

    # Try a read-only request on primaries until one succeeds.
    def _run_on_primary(self, containerName, primary_request, primary=None):
        if primary is None:
            partition, nodes = self._get_primary_nodes(containerName)
        else:
            partition, node = primary
            nodes = [node]

        failures = []

        for node in nodes:
            try:
                return primary_request(node, partition)

            except Exception as exc:
                failures.append(self._primary_failure(node, exc))

        raise self._all_primaries_failed(containerName, partition, failures)

    # Read a full shard-range listing from one primary.
    def _get_backend_shard_listing(
        self, containerName, headers=None, query_string=None, primary=None):
        request_headers = {
            "X-Backend-Record-Type": "shard",
            "X-Backend-Record-Shard-Format": "full",
        }

        if headers:
            request_headers.update(headers)

        # Issue the direct container request for one primary.
        def get_shard_listing(node, partition):
            extra_params = dict(parse_qsl(query_string)) if query_string else None

            _response_headers, listing = direct_client.direct_get_container(
                node,
                partition,
                self.account,
                containerName,
                headers=request_headers,
                extra_params=extra_params,
                conn_timeout=self.conn_timeout,
                response_timeout=self.response_timeout,
            )

            return [dict(item) for item in listing]

        return self._run_on_primary(
            containerName, get_shard_listing, primary=primary
        )

    # Format the primary identity included in a combined snapshot.
    def _format_primary(self, node, partition):
        return {
            "partition": partition,
            "ip": node.get("ip"),
            "port": node.get("port"),
            "device": node.get("device"),
        }

    # Save one primary failure without exposing request internals.
    def _primary_failure(self, node, exc):
        return {
            "ip": node.get("ip"),
            "port": node.get("port"),
            "device": node.get("device"),
            "error": repr(exc),
        }

    # Build the common error raised after every primary request fails.
    def _all_primaries_failed(self, containerName, partition, failures):
        details = "; ".join(
            (
                str(failure["ip"]) + ":" + str(failure["port"]) + "/"
                + str(failure["device"]) + ": " + str(failure["error"])
            )
            for failure in failures
        )

        return ObserverBackendError(
            "All primary container replicas failed while observing "
            + self.account + "/" + containerName + "; partition=" + str(partition)
            + "; failures=[" + details + "]"
        )

    # ------------------------------------------------------------------
    # Shard-range formatting
    # ------------------------------------------------------------------

    # Format a shard-range state as lowercase text.
    def _format_shard_state(self, state):
        if isinstance(state, str):
            # Some representations may already contain the textual state.
            stripped = state.strip()

            try:
                numeric_state = int(stripped)
            except ValueError:
                return stripped.lower()

            state = numeric_state

        try:
            state_name = ShardRange.STATES.get(state)
        except AttributeError:
            state_name = None

        if state_name is None:
            return str(state).lower()

        return str(state_name).lower()

    # Format one direct-client shard-range dictionary.
    def _format_shard_range(self, shard_range):
        deleted = shard_range.get("deleted", False)

        if isinstance(deleted, str):
            deleted = deleted.lower() in {"1","true","yes","on"}
        else:
            deleted = bool(deleted)

        return {
            "name": shard_range.get("name"),
            "range": {
                "lower": shard_range.get("lower", ""),
                "upper": shard_range.get("upper", ""),
            },
            "object_count": int(shard_range.get("object_count") or 0),
            "bytes_used": int(shard_range.get("bytes_used") or 0),
            "state": self._format_shard_state(shard_range.get("state")),
            "deleted": deleted,
            "epoch": shard_range.get("epoch"),
            "timestamp": shard_range.get("timestamp"),
            "meta_timestamp": shard_range.get("meta_timestamp"),
            "state_timestamp": shard_range.get("state_timestamp"),
        }

    # Return every shard state name known - possible states.
    def _known_shard_state_names(self):
        try:
            values = ShardRange.STATES.values()
        except AttributeError:
            return [
                "found",
                "created",
                "cleaved",
                "active",
                "shrinking",
                "sharding",
                "sharded",
                "shrunk",
            ]

        return sorted({str(value).lower() for value in values})

    # Count shard ranges by state for cleaner report.
    def _summarize_shard_ranges(self, shard_ranges):
        counts = Counter(shard_range["state"] for shard_range in shard_ranges)

        result = {
            "total": len(shard_ranges),
        }

        for state_name in self._known_shard_state_names():
            result[state_name] = counts.get(state_name, 0)

        for state_name, count in counts.items():
            result.setdefault(state_name, count)

        return result

    # Count shard ranges that completed cleaving.
    def _derive_cleaving_progress(self, shard_ranges):
        completed_states = {
            "cleaved", "active", "sharded", "shrunk"
        }

        ranges_done = 0
        for shard in shard_ranges:
            if shard["state"] in completed_states:
                ranges_done += 1

        total = len(shard_ranges)

        return {
            "ranges_done": ranges_done,
            "ranges_todo": total - ranges_done,
            "cleaving_done": ranges_done == total and total > 0,
            "source": "derived_from_shard_states",
        }

    # Build the compact shard distribution used in snapshots.
    def _distribution_from_ranges(self, shard_ranges):
        return [
            {
                "index": index,
                "name": shard_range["name"],
                "range": dict(shard_range["range"]),
                "object_count": shard_range["object_count"],
                "bytes_used": shard_range["bytes_used"],
                "state": shard_range["state"],
            }
            for index, shard_range in enumerate(shard_ranges, start=1)
        ]

    # Return a header value using a case-insensitive name.
    def _get_header(self, headers, wanted_name):
        lower_name = wanted_name.lower()

        for key, value in headers.items():
            if str(key).lower() == lower_name:
                return value

        return None

    # Return a header as an integer, or the given default when absent.
    def _header_as_int(self, headers, name, default=0):
        value = self._get_header(headers, name)

        if value is None:
            return default

        return int(value)
