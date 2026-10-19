"""Time sequential object insertion while the container remains unsharded.

The threshold is prepared by the probe environment before this test starts.
This test deliberately does not change Swift configuration; it only uses the
Workloader to create one container and insert batches of real objects.
"""

import os
import time
import unittest
import uuid

from swift.common.ring import Ring
from swiftclient.client import Connection

from probe.common.observer import Observer
from probe.common.workloader import Workloader


class TestInsertionBenchmark(unittest.TestCase):
    SHARDING_THRESHOLD = 10000
    BATCH_SIZE = 50
    DEADLINE_SECONDS = 20 * 60
    OBJECT_SIZE = 60
    CLEANUP_RETRY_INTERVAL = 5.0

    def setUp(self):
        project = os.environ.get("OS_PROJECT_NAME") or os.environ.get(
            "OS_TENANT_NAME"
        )
        if not project:
            raise RuntimeError("OS_PROJECT_NAME or OS_TENANT_NAME must be set")

        self.conn = Connection(
            authurl=os.environ["OS_AUTH_URL"],
            user=os.environ["OS_USERNAME"],
            key=os.environ["OS_PASSWORD"],
            auth_version="3",
            os_options={
                "project_name": project,
                "region_name": os.environ.get("OS_REGION_NAME", "Edmonton"),
                "project_domain_name": os.environ.get(
                    "OS_PROJECT_DOMAIN_NAME", "Default"
                ),
                "user_domain_name": os.environ.get(
                    "OS_USER_DOMAIN_NAME", "Default"
                ),
            },
            insecure=True,
        )
        url, token = self.conn.get_auth()
        account = url.rstrip("/").split("/")[-1]
        ring = Ring(os.environ.get("SWIFT_CONFIG_DIR", "/etc/swift"),
                    ring_name="container")

        self.workloader = Workloader(self.conn)
        self.observer = Observer(
            url=url,
            token=token,
            account=account,
            container_ring=ring,
        )
        self.container = "probe-insertion-benchmark-" + uuid.uuid4().hex[:12]

    def tearDown(self):
        # Cleanup is intentionally unbounded.  A slow or temporarily
        # unavailable Swift deployment must not leave benchmark data behind,
        # and the outer runner must not impose a timeout on this phase.
        attempt = 0
        while True:
            attempt += 1
            result = self.workloader.cleanup()
            print(
                "CLEANUP attempt {0}: deleted={1} objects, "
                "container_deleted={2}, elapsed={3:.2f}s, success={4}".format(
                    attempt,
                    result.get("real_objects_deleted", 0),
                    result.get("container_deleted", False),
                    result.get("elapsed", 0.0),
                    result.get("success", False),
                ),
                flush=True,
            )
            if result.get("success", False):
                return
            print(
                "CLEANUP will retry in {0:.1f}s: {1}".format(
                    self.CLEANUP_RETRY_INTERVAL,
                    repr(result.get("errors", [])),
                ),
                flush=True,
            )
            time.sleep(self.CLEANUP_RETRY_INTERVAL)

    def test_insertion_until_deadline(self):
        start = time.monotonic()
        deadline = start + self.DEADLINE_SECONDS
        inserted = 0
        batch_number = 0

        print("\n============================================================", flush=True)
        print("INSERTION BENCHMARK", flush=True)
        print("threshold: {0}".format(self.SHARDING_THRESHOLD), flush=True)
        print("batch size: {0} objects".format(self.BATCH_SIZE), flush=True)
        print("deadline: {0} seconds".format(self.DEADLINE_SECONDS), flush=True)
        print("container: {0}".format(self.container), flush=True)
        print("============================================================", flush=True)

        self.workloader.create_container(self.container)
        print("container created", flush=True)

        # Leave one row below the configured threshold.  This guarantees that
        # the benchmark remains an insertion-only, unsharded measurement even
        # if the deployment is fast enough to reach the threshold.
        maximum_objects = self.SHARDING_THRESHOLD - 1
        while time.monotonic() < deadline and inserted < maximum_objects:
            remaining = maximum_objects - inserted
            count = min(self.BATCH_SIZE, remaining)
            batch_number += 1
            batch_start = time.monotonic()
            result = self.workloader.insert_objects(
                self.container,
                count,
                start_index=inserted,
                object_size=self.OBJECT_SIZE,
            )
            batch_elapsed = time.monotonic() - batch_start
            inserted += result["successful"]

            self.assertEqual(
                result["successful"],
                count,
                "insertion batch failed: " + repr(result),
            )
            self.assertEqual(result["failed"], 0, repr(result))

            observed_count = self.observer.get_container_object_count(
                self.container
            )
            total_elapsed = time.monotonic() - start
            print(
                "batch {0}: requested={1}, inserted={2}, "
                "batch_time={3:.2f}s, rate={4:.2f} objects/s, "
                "total_objects={5}, observed_objects={6}, elapsed={7:.2f}s".format(
                    batch_number,
                    count,
                    result["successful"],
                    batch_elapsed,
                    result["successful"] / batch_elapsed
                    if batch_elapsed > 0
                    else 0.0,
                    inserted,
                    observed_count,
                    total_elapsed,
                ),
                flush=True,
            )

        total_elapsed = time.monotonic() - start
        total_rate = inserted / total_elapsed if total_elapsed > 0 else 0.0
        final_stats = self.observer.get_container_stats(self.container)

        print("------------------------------------------------------------", flush=True)
        print("SUMMARY", flush=True)
        print("batches: {0}".format(batch_number), flush=True)
        print("objects inserted: {0}".format(inserted), flush=True)
        print("total elapsed: {0:.2f}s".format(total_elapsed), flush=True)
        print("average rate: {0:.2f} objects/s".format(total_rate), flush=True)
        print("observed object count: {0}".format(
            final_stats["object_count"]
        ), flush=True)
        print("threshold safety margin: {0} objects".format(
            self.SHARDING_THRESHOLD - inserted
        ), flush=True)
        print("cleanup will run in tearDown", flush=True)

        self.assertEqual(final_stats["object_count"], inserted)
        self.assertLess(inserted, self.SHARDING_THRESHOLD)


if __name__ == "__main__":
    unittest.main()
