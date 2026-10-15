"""Final Observer + workloader test for the 1,000-row sharding profile.

The test will have the following goals:

Showing creation and management of multiple containers by the workloader.
Showing mass insertion and creation of objects using the workloader.
Using the observer to show data on sharding status and progress.
Using the observer to show data on different shard ranges.
Verifying sharding works consistently on different container sizes.
Using the workloader for cleanup and deletion of objects and containers.


"""


import math
import os
from pprint import pformat
import random
import time
import unittest
import uuid
import warnings

from swift.common.ring import Ring
from swiftclient.client import ClientException, Connection

from probe.common.observer import Observer
from probe.common.workloader import Workloader

# This unittest must be run with the environment prepared by probe/run_probe.sh.
class TestFinalShardingWorkload(unittest.TestCase):
    SHARDING_THRESHOLD = 1000
    ROWS_PER_SHARD = SHARDING_THRESHOLD // 2
    MINIMUM_SHARD_SIZE = ROWS_PER_SHARD // 5
    SHARDING_TIMEOUT = 900.0
    CLEANUP_TIMEOUT = 1800.0
    POLL_INTERVAL = 1.0


    # Set up the connections, names, constants, and resources used by the test.
    # unittest.TestCase calls this method before the test runs.
    def setUp(self):
        warnings.simplefilter("ignore", ResourceWarning)
        warnings.simplefilter("ignore", DeprecationWarning)

        # Import account information from os.environ and generate a connection.
        openstack_project = os.environ.get("OS_PROJECT_NAME") or os.environ.get(
            "OS_TENANT_NAME"
        )
        if not openstack_project:
            raise RuntimeError(
                "OS_PROJECT_NAME or OS_TENANT_NAME must be set"
            )
        self.conn = Connection(
            authurl=os.environ["OS_AUTH_URL"],
            user=os.environ["OS_USERNAME"],
            key=os.environ["OS_PASSWORD"],
            tenant_name=openstack_project,
            auth_version="3",
            os_options={
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
        self.sample_object_check_count = 5

        # Generate unique container names so concurrent or repeated runs do not
        # operate on the same resources.
        suffix = uuid.uuid4().hex[:8]
        self.containers = [
            "probe-final-sharding-" + str(number) + "-" + suffix
            for number in range(1, 4)
        ]
        url, token = self.conn.get_auth()
        account = url.rstrip("/").split("/")[-1]
        ring = Ring("/etc/swift", ring_name="container")

        # Set up a Workloader using the authenticated Swift connection.
        self.workloader = Workloader(self.conn)

        # Set up an Observer using the information needed for requests.
        self.observer = Observer(
            url=url, token=token, account=account, container_ring=ring
        )

    # Make sure Workloader-owned containers are deleted at the end.
    # unittest.TestCase calls this method after the test runs.
    def tearDown(self):
        cleanup_result = self.workloader.cleanup()
        if not cleanup_result["success"]:
            print("WARNING: final safety cleanup failed:", repr(cleanup_result))


    # Return only interesting sharding related data from a snapshot.
    def _compact_snapshot(self, snapshot):
        return {
            "backend_primary": snapshot.get("backend_primary"),
            "root_state": snapshot["sharding_state"],
            "sharding_phase": snapshot["sharding_phase"],
            "proxy_object_count": snapshot["object_count"],
            "proxy_listing_count": snapshot.get("proxy_listing_count"),
            "proxy_listing_matches_tracked": snapshot.get(
                "proxy_listing_matches_tracked"
            ),
            "bytes_used": snapshot["bytes_used"],
            "shard_count": snapshot["shard_count"],
            "shard_summary": snapshot["shard_summary"],
            "cleaving_progress": snapshot["cleaving_progress"],
            "shards": snapshot["shards"],
            "shard_metadata_count": snapshot.get("shard_metadata_count"),
        }

    # An iterative function that can perform calls until the snapshot
    # reaches a desired state, such as starting or finishing sharding.
    def _wait_until_shards(self, containerName, condition, description):
        # Set a deadline so the task will always end.
        startTime = time.monotonic()
        deadline = startTime + self.SHARDING_TIMEOUT
        lastSnapshot = None
        last_signature = None

        # Loop until the condition is true or the deadline is reached.
        while time.monotonic() < deadline:
            # Using the observer to inspect sharding data.
            lastSnapshot = self.observer.get_container_snapshot(containerName)
            signature = (
                lastSnapshot["sharding_state"],
                lastSnapshot["shard_count"],
                tuple(sorted((lastSnapshot["shard_summary"] or {}).items())),
                lastSnapshot["object_count"],
                tuple(
                    shard["object_count"]
                    for shard in (lastSnapshot.get("shards") or [])
                ),
            )
            # Show when changes occur in the snapshot.
            if signature != last_signature:
                print()
                print(
                    containerName,
                    ": state change at +{:.1f}s:".format(
                        time.monotonic() - startTime
                    ),
                )
                print(
                    pformat(
                        self._compact_snapshot(lastSnapshot),
                        sort_dicts=True,
                        width=110,
                    ),
                    flush=True,
                )
                last_signature = signature
            # If the condition is fulfilled, return the last snapshot and elapsed time.
            if condition(lastSnapshot):
                return lastSnapshot, time.monotonic() - startTime
            time.sleep(self.POLL_INTERVAL)
        # If the timeout is reached, invoke failure.
        self.fail(
            "Timed out waiting for " + containerName + " " + description
            + "; lastSnapshot=" + repr(lastSnapshot)
        )

    # Wait until sharding starts in the container.
    def _wait_for_sharding_start(self, containerName):
        return self._wait_until_shards(
            containerName,
            self._sharding_has_started,
            "to start sharding",
        )

    # Check whether sharding has started in a snapshot.
    def _sharding_has_started(self, snapshot):
        return snapshot["sharding_phase"] == Observer.SHARDING_PHASE_STARTED

    # Calculate the minimum and maximum possible number of shards.
    def _shard_count_bounds(self, expected_count):
        return (
            math.ceil(expected_count / self.SHARDING_THRESHOLD),
            math.ceil(expected_count / self.ROWS_PER_SHARD),
        )

    # Check whether the snapshot shows completion of all shards.
    # Verify by comparing objects in shards against the expected number.
    def _snapshot_is_fully_sharded(
        self, snapshot, expected_count, containerName
    ):
        shards = snapshot.get("shards") or []
        shard_count = len(shards)
        # Also verify the shard count is within the expected possible range.
        minimum_shards, maximum_shards = self._shard_count_bounds(
            expected_count
        )
        distributed_count = sum(
            shard["object_count"]
            for shard in shards
        )
        metadata_is_complete = (
            snapshot["sharding_state"] == "sharded"
            and snapshot["object_count"] == expected_count
            and snapshot["cleaving_progress"].get("cleaving_done") is True
            and minimum_shards <= shard_count <= maximum_shards
            and all(
                self.MINIMUM_SHARD_SIZE <= shard["object_count"]
                <= self.SHARDING_THRESHOLD
                for shard in shards
            )
            and distributed_count == expected_count
        )

        if not metadata_is_complete:
            return False

        visible_objects = self.observer.get_container_objects(containerName)
        visible_names = {entry["name"] for entry in visible_objects}
        tracked_names = self.workloader.real_objects.get(containerName, set())
        snapshot["proxy_listing_count"] = len(visible_objects)
        snapshot["proxy_listing_matches_tracked"] = (
            visible_names == tracked_names
        )

        return (
            snapshot["proxy_listing_count"] == expected_count
            and snapshot["proxy_listing_matches_tracked"]
        )

    # Perform checks over shard distribution and verify that values are in a
    # valid range.
    def _assert_shard_distribution(self, snapshot, expected_count):
        shards = snapshot["shards"]
        shard_count = len(shards)
        minimum_shards, maximum_shards = self._shard_count_bounds(
            expected_count
        )
        distributed_count = sum(
            shard["object_count"]
            for shard in shards
        )
        self.assertGreaterEqual(shard_count, minimum_shards, snapshot)
        self.assertLessEqual(shard_count, maximum_shards, snapshot)
        for shard in shards:
            self.assertGreaterEqual(
                shard["object_count"],
                self.MINIMUM_SHARD_SIZE,
                shard,
            )
            self.assertLessEqual(
                shard["object_count"],
                self.SHARDING_THRESHOLD,
                shard,
            )
        self.assertEqual(expected_count, distributed_count, snapshot)
    # Wait for proxy visibility and backend convergence using Observer's
    # reusable wait helpers, then perform the expensive correctness checks
    # exactly once on the final snapshot.
    def _wait_for_sharded(self, containerName, expected_count):
        startTime = time.monotonic()

        count_snapshot = self.observer.wait_until_expected_count(
            containerName,
            expected_count,
            timeout=self.SHARDING_TIMEOUT,
            poll_interval=self.POLL_INTERVAL,
        )
        count_elapsed = time.monotonic() - startTime
        remaining = self.SHARDING_TIMEOUT - count_elapsed

        if remaining < 0:
            self.fail(
                "Timed out waiting for " + containerName
                + " to reach " + str(expected_count)
                + " visible objects; lastSnapshot=" + repr(count_snapshot)
            )

        stable_snapshot = self.observer.wait_until_stable(
            containerName,
            timeout=remaining,
            poll_interval=self.POLL_INTERVAL,
        )

        if not self._snapshot_is_fully_sharded(
            stable_snapshot,
            expected_count,
            containerName,
        ):
            self.fail(
                "Final snapshot failed sharding validation for "
                + containerName
                + ": "
                + repr(self._compact_snapshot(stable_snapshot))
            )

        return stable_snapshot, time.monotonic() - startTime

    # Verify that sampled GET requests return each object's expected content.
    # Compare a sample of the objects against their expected values
    def _assert_sample_objects(
        self, containerName, objectNames, content_prefix, sample_count
    ):
        for objectName in random.sample(objectNames, sample_count):
            _headers, actual_body = self.workloader.get_object(
                containerName,
                objectName,
            )
            expected_body = self.workloader.build_object_content(
                containerName,
                objectName,
                content_prefix,
            )
            self.assertIsNotNone(actual_body)
            self.assertEqual(expected_body, actual_body)

    # Use the workloader to clean up each container.

    def _cleanup_and_verify(self, containerName):
        startTime = time.monotonic()
        deadline = startTime + self.CLEANUP_TIMEOUT
        attempts = 0
        last = None
        # Container cleanup is a long process because it finishes only after
        # all replicated copies are deleted.
        # Document attempts and elapsed time until completion.
        while time.monotonic() < deadline:
            attempts += 1
            last = self.workloader.cleanup_container(containerName)
            try:
                self.conn.head_container(containerName)
            except ClientException as exc:
                if exc.http_status == 404:
                    self.assertTrue(last["container_deleted"], last)
                    self.assertNotIn(
                        containerName,
                        self.workloader.get_managed_containers(),
                    )
                    print()
                    print("Cleanup verified for", containerName + ":")
                    print(
                        pformat(
                            {
                                "attempts": attempts,
                                "elapsed": time.monotonic() - startTime,
                            },
                            sort_dicts=True,
                            width=110,
                        ),
                        flush=True,
                    )
                    return
                raise
            time.sleep(self.POLL_INTERVAL)
        # Since deletion takes a long time, CLEANUP_TIMEOUT should be large.
        self.fail(
            "Timed out cleaning " + containerName + "; last=" + repr(last)
        )
        return None

    def test_three_container_final_workload(self):
        # Final workload showing workloader and observer abilities
        # Will perform verification and test both for correct behavior.

        firstContainerName, secondContainerName, thirdContainerName = (
            self.containers
        )
        # Creating and activating sharding using the workloader
        for containerName in self.containers:
            self.assertTrue(self.workloader.create_container(containerName))
            self.assertTrue(
                self.workloader.set_container_sharding(
                    containerName, enabled=True
                )
            )

        ########################################################
        #               The main test phase
        #
        # Creation of 3 containers using the workloader
        # Container sizes will be - 1001, 2250, 3500
        # For each container:
        # Insertion of all objects using workloader
        # Report sharding progress using the observer
        # Verify sharding data is sensible and possible.
        # Perform full cleanup using the workloader.
        #
        # Will show elapsed times for each container and output data


        # Container 1 - 1001 objects
        print("\n" + "=" * 78)
        print("CONTAINER 1: 1,001 objects")
        print("=" * 78, flush=True)
        startTime = time.monotonic()
        first_content_prefix = b"probe-final-1:"
        first_upload = self.workloader.insert_objects(
            firstContainerName,
            1001,
            prefix="real-c1-",
            content_prefix=first_content_prefix,
        )
        self.assertEqual(1001, first_upload["successful"], first_upload)
        print("\nContainer 1 insertion timing:")
        print(
            pformat(
                {"elapsed": time.monotonic() - startTime},
                sort_dicts=True,
                width=110,
            ),
            flush=True,
        )
        self._wait_for_sharding_start(firstContainerName)
        first_final_snapshot, _ = self._wait_for_sharded(
            firstContainerName,
            1001,
        )
        self._assert_shard_distribution(first_final_snapshot, 1001)
        self._assert_sample_objects(
            firstContainerName,
            first_upload["successful_names"],
            first_content_prefix,
            self.sample_object_check_count,
        )
        print("\nContainer 1 final sharded state:")
        print(
            pformat(
                self._compact_snapshot(first_final_snapshot),
                sort_dicts=True,
                width=110,
            ),
            flush=True,
        )

        # Container 2 - 2250 objects
        print("\n" + "=" * 78)
        print("CONTAINER 2: 2,250 objects")
        print("=" * 78, flush=True)
        startTime = time.monotonic()
        second_content_prefix = b"probe-final-2:"
        second_upload = self.workloader.insert_objects(
            secondContainerName,
            2250,
            prefix="real-c2-",
            content_prefix=second_content_prefix,
        )
        self.assertEqual(2250, second_upload["successful"], second_upload)
        print("\nContainer 2 insertion timing:")
        print(
            pformat(
                {"elapsed": time.monotonic() - startTime},
                sort_dicts=True,
                width=110,
            ),
            flush=True,
        )
        self._wait_for_sharding_start(secondContainerName)
        second_final_snapshot, _ = self._wait_for_sharded(
            secondContainerName,
            2250,
        )
        self._assert_shard_distribution(second_final_snapshot, 2250)
        self._assert_sample_objects(
            secondContainerName,
            second_upload["successful_names"],
            second_content_prefix,
            self.sample_object_check_count,
        )
        print("\nContainer 2 final sharded state:")
        print(
            pformat(
                self._compact_snapshot(second_final_snapshot),
                sort_dicts=True,
                width=110,
            ),
            flush=True,
        )

        # Container 3 - 3500 objects
        print("\n" + "=" * 78)
        print("CONTAINER 3: 3,500 objects")
        print("=" * 78, flush=True)
        startTime = time.monotonic()
        third_content_prefix = b"probe-final-3:"
        third_upload = self.workloader.insert_objects(
            thirdContainerName,
            3500,
            prefix="real-c3-",
            content_prefix=third_content_prefix,
        )
        self.assertEqual(3500, third_upload["successful"], third_upload)
        print("\nContainer 3 insertion timing:")
        print(
            pformat(
                {"elapsed": time.monotonic() - startTime},
                sort_dicts=True,
                width=110,
            ),
            flush=True,
        )
        self._wait_for_sharding_start(thirdContainerName)
        third_final_snapshot, _ = self._wait_for_sharded(
            thirdContainerName,
            3500,
        )
        self._assert_shard_distribution(third_final_snapshot, 3500)
        self._assert_sample_objects(
            thirdContainerName,
            third_upload["successful_names"],
            third_content_prefix,
            self.sample_object_check_count,
        )
        print("\nContainer 3 final sharded state:")
        print(
            pformat(
                self._compact_snapshot(third_final_snapshot),
                sort_dicts=True,
                width=110,
            ),
            flush=True,
        )

        # Use the workloader to delete objects and containers at the end.
        # Test the cleanup method and verify that the containers are deleted.
        print("\n" + "=" * 78)
        print("CLEANUP: verify deletion one container at a time")
        print("=" * 78, flush=True)
        for containerName in self.containers:
            self._cleanup_and_verify(containerName)


if __name__ == "__main__":
    unittest.main()
