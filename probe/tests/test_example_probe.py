"""One example probe composed of authentication, CRUD, and ring stages."""

import ipaddress
import os
import unittest
import uuid
import warnings

from swift.common import direct_client
from swift.common.exceptions import ClientException as SwiftClientException
from swift.common.ring import Ring
from swiftclient.client import ClientException, Connection


class TestExampleProbe(unittest.TestCase):
    def setUp(self):
        # Lifecycle visibility only; this method creates no Swift resources.
        # In the future we will establish recources for the test in setUp
        print("\nsetUp called for " + self._testMethodName)

    def tearDown(self):
        # Cleanup is performed inside object_round_trip().
        # In the future we might add here a sequence which ensures cleanup
        print("tearDown called for " + self._testMethodName)

    def authenticate(self):
        # Create one connection and return it for the remaining probe stages.
        projectName = os.environ.get("OS_PROJECT_NAME") or os.environ.get(
            "OS_TENANT_NAME"
        )
        self.assertTrue(projectName, "authentication missing project name")
        connection = Connection(
            authurl=os.environ["OS_AUTH_URL"],
            user=os.environ["OS_USERNAME"],
            key=os.environ["OS_PASSWORD"],
            auth_version="3",
            os_options={
                "project_name": projectName,
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
        storageUrl, token = connection.get_auth()
        # Assert connection has been established and report success
        self.assertTrue(storageUrl, "authentication returned no storage URL")
        self.assertTrue(token, "authentication returned no token")
        return connection, storageUrl.rstrip("/").split("/")[-1]

    def object_round_trip(self, connection):
        # Use the passed connection for the complete public object lifecycle.
        # Using a uuid for unique names for the test
        suffix = uuid.uuid4().hex[:8]
        containerName = "probe-example-" + suffix
        objectName = "example-object"
        objectContent = b"Swiftacular example probe"
        # creation of container
        connection.put_container(containerName)

        try:
            # insertion of object
            connection.put_object(
                containerName, objectName, contents=objectContent
            )
            try:
                # Get request to the object
                objectHeaders, downloadedContent = connection.get_object(
                    containerName, objectName
                )
            except Exception as error:
                self.fail("round trip failed at GET request: " + repr(error))
            self.assertEqual(
                objectContent,
                downloadedContent,
                "round trip failed at GET content validation",
            )
            self.assertEqual(
                len(objectContent),
                int(objectHeaders["content-length"]),
                "round trip failed at GET length validation",
            )
        finally:
            try:
            # deletation of the object and container
                connection.delete_object(containerName, objectName)
            except ClientException as error:
                if error.http_status != 404:
                    raise
            finally:
                try:
                    connection.delete_container(containerName)
                except ClientException as error:
                    if error.http_status != 404:
                        raise

    def inspect_ring_topology(self, accountName):
        # Read ring topology without creating or changing Swift resources.
        # Load the container ring so Swift can calculate backend placement.
        containerRing = Ring(os.environ["SWIFT_CONFIG_DIR"], ring_name="container")

        # Map logical account/container pair to a partition and primaries.
        nonexistentContainer = "probe-nonexistent-" + uuid.uuid4().hex
        partition, primaryNodes = containerRing.get_nodes(
            accountName, nonexistentContainer)
        self.assertTrue(primaryNodes, "ring lookup returned no primary nodes")

        # Read the storage addresses, verify they are valid IP addresses.
        configuredAddresses = {
            os.environ["SWIFT_STORAGE_1_IP"],
            os.environ["SWIFT_STORAGE_2_IP"],
            os.environ["SWIFT_STORAGE_3_IP"],
        }
        for address in configuredAddresses:
            ipaddress.ip_address(address)

        # Extract the primary addresses selected by the ring.
        ringAddresses = {str(node["ip"]) for node in primaryNodes}

        # Verify that ring placement matches the discovered Swift topology.
        self.assertTrue(
            ringAddresses.issubset(configuredAddresses),
            "ring primary addresses " + repr(ringAddresses)
            + " are not contained in generated topology addresses "
            + repr(configuredAddresses),
        )

        # Query one primary directly. The container is intentionally absent,
        # so a 404 proves the storage server received and understood the call.
        selectedNode = primaryNodes[0]
        try:
            # The expected 404 is kept as an assertion, not shown in output.
            direct_client.direct_head_container(
                selectedNode,
                partition,
                accountName,
                nonexistentContainer,
            )
        except SwiftClientException as error:
            self.assertEqual(
                404,
                error.http_status,
                "direct request returned an unexpected status",
            )
        else:
            self.fail(
                "direct request unexpectedly found nonexistent container "
                + nonexistentContainer
            )


    def test_example_probe(self):
        # Run all test stages one by one and report failures.

        warnings.simplefilter("ignore", DeprecationWarning)
        warnings.simplefilter("ignore", ResourceWarning)
        # Connection establishment test
        try:
            connection, accountName = self.authenticate()
            print("[PASS] authentication")
        except Exception as error:
            self.fail("authentication failed: " + repr(error))
        # Object round trip test
        try:
            self.object_round_trip(connection)
            print("[PASS] object round trip")
        except Exception as error:
            self.fail("round trip failed: " + repr(error))
        #
        try:
            self.inspect_ring_topology(accountName)
            print("[PASS] direct ring and storage request")
        except Exception as error:
            self.fail("direct storage topology check failed: " + repr(error))


if __name__ == "__main__":
    unittest.main()
