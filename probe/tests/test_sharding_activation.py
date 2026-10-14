# This is a small test to confirm sharding starts correctly after a threshould change

import os
import time
import unittest
import uuid

from swift.common import direct_client
from swift.common.exceptions import ClientException as SwiftClientException
from swift.common.ring import Ring
from swiftclient.client import ClientException, Connection

# Time variables in second
SHARDING_START_TIMEOUT = 300
SHARDING_POLL_INTERVAL = 5
SHARDING_CLEANUP_TIMEOUT = 600


class TestShardingActivation(unittest.TestCase):
    def setUp(self):
        """Authenticate and create an isolated container for the test."""
        self.conn, self.account = self._connect()

        self.container = "probe-sharding-" + uuid.uuid4().hex[:12]
        self.objects = []
        self.conn.put_container(self.container)
        print(
            "ACTIVATION: authenticated and created container "
            + self.container
            + "; moving to add objects below the sharding threshold",
            flush=True,
        )

    def tearDown(self):
        """Remove objects and the test container, waiting for sharding to settle."""
        for name in self.objects:
            try:
                self.conn.delete_object(self.container, name)
            except ClientException as error:
                if error.http_status != 404:
                    raise

        # Container deletion can return 409 while the sharder is publishing
        # shard ranges. Wait for a stable sharded state before retrying.
        cleanup_deadline = time.monotonic() + SHARDING_CLEANUP_TIMEOUT
        while time.monotonic() < cleanup_deadline:
            try:
                state, _shard_states, _started = self._backend_state(
                    self.account, self.container
                )
                if state == "sharded":
                    break
            except Exception:
                pass
            time.sleep(3)

        while True:
            try:
                self.conn.delete_container(self.container)
                break
            except ClientException as error:
                if error.http_status == 404:
                    break
                if error.http_status != 409:
                    raise
                if time.monotonic() >= cleanup_deadline:
                    raise
                time.sleep(3)

    def _connect(self):
        # set up a connection in the test
        project = os.environ.get("OS_PROJECT_NAME") or os.environ.get("OS_TENANT_NAME")
        conn = Connection(
            authurl=os.environ["OS_AUTH_URL"], user=os.environ["OS_USERNAME"],
            key=os.environ["OS_PASSWORD"], auth_version="3",
            os_options={"project_name": project, "region_name": os.environ.get("OS_REGION_NAME", "Edmonton"),
                        "project_domain_name": os.environ.get("OS_PROJECT_DOMAIN_NAME", "Default"),
                        "user_domain_name": os.environ.get("OS_USER_DOMAIN_NAME", "Default")},
            insecure=True,
        )
        storage_url, token = conn.get_auth()
        self.assertTrue(storage_url and token)
        return conn, storage_url.rstrip("/").split("/")[-1]

    def _backend_state(self, account, container):
        # Gather backend information for verification such as:
        ring = Ring(os.environ["SWIFT_CONFIG_DIR"], ring_name="container")
        partition, nodes = ring.get_nodes(account, container)
        headers = direct_client.direct_head_container(
            nodes[0], partition, account, container,
            conn_timeout=5,
            response_timeout=10,
        )
        listing = []
        state = (headers.get("x-backend-sharding-state") or "").lower()
        shard_states = []
        started = state in {"sharding", "sharded"} or any(
            value in {"sharding", "sharded", "shrinking"} for value in shard_states
        )
        return state, shard_states, started

    def test_threshold_crossing_starts_sharding(self):
        # Read the threshold prepared for this probe run.
        threshold = int(os.environ["EXPECTED_SHARD_CONTAINER_THRESHOLD"])

        # Insert threshold - 1 objects into the container.
        for index in range(threshold - 1):
            name = "object-%06d" % index
            self.conn.put_object(
                self.container,
                name,
                contents=b"probe",
                content_type="application/octet-stream",
            )
            self.objects.append(name)
        print(
            "ACTIVATION: added "
            + str(threshold - 1)
            + " objects (threshold - 1); verifying the container remains unsharded",
            flush=True,
        )

        # Confirm sharding has not started below the configured threshold.
        state, shard_states, started = self._backend_state(
            self.account, self.container
        )
        self.assertFalse(started, (state, shard_states))
        print(
            "ACTIVATION: verified the below-threshold state is "
            + state
            + "; inserting the final object to cross the threshold",
            flush=True,
        )

        # Insert one more object to cross the threshold.
        name = "object-%06d" % (threshold - 1)
        self.conn.put_object(
            self.container,
            name,
            contents=b"probe",
            content_type="application/octet-stream",
        )
        self.objects.append(name)
        print(
            "ACTIVATION: inserted "
            + str(threshold)
            + " objects and crossed the threshold; waiting for sharding to start",
            flush=True,
        )

        deadline = time.monotonic() + SHARDING_START_TIMEOUT
        started = False
        while time.monotonic() < deadline:
            state, shard_states, started = self._backend_state(
                self.account, self.container
            )
            if started:
                break
            time.sleep(SHARDING_POLL_INTERVAL)
        self.assertTrue(started, "sharding did not start before timeout")
        print(
            "ACTIVATION: verified sharding started after reaching threshold "
            + str(threshold)
            + "; verifying the container remains readable",
            flush=True,
        )

        _headers, listing = self.conn.get_container(self.container)
        self.assertGreaterEqual(len(listing), threshold)
        print(
            "ACTIVATION: PASS - sharding activated and all inserted objects remain available",
            flush=True,
        )


if __name__ == "__main__":
    unittest.main()

