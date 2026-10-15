"""
Probe-test workload helper for Swiftacular.

Workloader creates real Swift objects through the public Swift API. These
objects have data stored on object servers and are sharded appropriately.

The current version of the Workloader:
    * Uses only public Swift calls to the proxy
    * Operates only on a small list of managed containers
    * Uses simple sequential actions
    * Does not use bulk middleware for requests
    * Does not use threads or concurrency

Some performance improvements might be necessary in the future.
"""

import random
import time

from swiftclient.exceptions import ClientException


class Workloader:
    # The workloader will create and manage Swift workloads for probe tests.

    DEFAULT_NAME_WIDTH = 6
    DEFAULT_REAL_PREFIX = "object-"
    DEFAULT_CONTENT_TYPE = "application/octet-stream"

    def __init__(self, conn, default_content_type=DEFAULT_CONTENT_TYPE):
        self.conn = conn
        self.default_content_type = default_content_type

        # Containers created through this Workloader instance.
        self.active_containers = set()

        # Best-effort bookkeeping; Swift remains the source of truth.
        self.real_objects = {}

    # ==================================================================
    # Internal helpers
    # ==================================================================

    def _make_names(self, count, prefix, start_index=0, name_width=DEFAULT_NAME_WIDTH):
        # Build deterministic object names - consistent naming format.

        if count < 0:
            raise ValueError("count must be >= 0")

        if start_index < 0:
            raise ValueError("start_index must be >= 0")

        if name_width <= 0:
            raise ValueError("name_width must be > 0")

        return [
            prefix + str(index).zfill(name_width)
            for index in range(start_index, start_index + count)
        ]

    def _result(self, *, action, requested,
        successful_names, failed, elapsed, **extra,):
        # Build the standard result returned by workload operations.

        successful = len(successful_names)
        failed_count = len(failed)
        # When using the workloader we will return results as the following format.
        result = {
            "action": action,
            "requested": requested,
            "successful": successful,
            "failed": failed_count,
            "successful_names": list(successful_names),
            "errors": list(failed),
            "elapsed": elapsed,
            "rate": successful / elapsed if elapsed > 0 else 0.0,
        }

        result.update(extra)

        return result

    def _is_container_owned(self, containerName):
        # Only allow the workloader to interact with containers it owns!
        if containerName not in self.active_containers:
            raise ValueError(
                "Container " + repr(containerName)
                + " is not managed by this Workloader"
            )

    def build_object_content(self, containerName, object_name,
        content_prefix=b"", object_size=None):
        # Build deterministic object content from its container and name.
        # The idea is to be able to verify content without saving it
        if not isinstance(content_prefix, bytes):
            raise TypeError("content_prefix must be bytes")

        identity = (containerName + "/" + object_name).encode("utf-8")
        content = content_prefix + identity
        if object_size is None:
            return content
        if object_size < len(content):
            raise ValueError(
                "object_size must fit the content prefix, container, and "
                "object name"
            )
        return content.ljust(object_size, b"x")

    # ==================================================================
    # Container lifecycle
    # ==================================================================

    def create_container(self, containerName, headers=None):
        # Create and own a new container.

        try:
            self.conn.head_container(containerName)
        except ClientException as exc:
            if getattr(exc, "http_status", None) != 404:
                raise
        else:
            raise ValueError(
                "Refusing to manage existing container " + repr(containerName)
            )

        self.conn.put_container(containerName, headers=headers)
        # Add container to a list of owned containers
        self.active_containers.add(containerName)
        self.real_objects.setdefault(containerName, set())

        return True

    def set_container_sharding(self, containerName, enabled=True):
        # Enable or disable sharding on a managed container.
        self._is_container_owned(containerName)
        sharding_value = "on" if enabled else "off"
        self.conn.post_container(
            containerName, headers={"X-Container-Sharding": sharding_value}
        )
        return True

    def delete_container(self, containerName):
        # Delete a managed container only when it is already empty.

        self._is_container_owned(containerName)
        self.conn.delete_container(containerName)

        self.active_containers.discard(containerName)
        self.real_objects.pop(containerName, None)

        return True

    def get_managed_containers(self):
        # Return the containers owned by this Workloader.

        return sorted(self.active_containers)

    # ==================================================================
    # Interact with Swift objects using public swift requests
    # ==================================================================

    def insert_objects(self, containerName, count, *, prefix=DEFAULT_REAL_PREFIX,
        start_index=0, name_width=DEFAULT_NAME_WIDTH, content_prefix=b"",
        object_size=None, content_type=None):
        # Upload objects through the public Swift API.
        # Object names and content are generated by a helper.
        # functions which create the standard format

        self._is_container_owned(containerName)

        if not isinstance(content_prefix, bytes):
            raise TypeError("content_prefix must be bytes")

        names = self._make_names(count, prefix, start_index, name_width)
        actual_content_type = content_type or self.default_content_type

        successful = []
        failed = []

        startTime = time.monotonic()
        # Build then insert each object
        for objectName in names:
            payload = self.build_object_content(
                containerName,
                objectName,
                content_prefix,
                object_size,
            )
            try:
                self.conn.put_object(
                    containerName,
                    objectName,
                    contents=payload,
                    content_type=actual_content_type,
                )

                successful.append(objectName)

            except Exception as exc:
                failed.append(
                    {
                        "name": objectName,
                        "error": repr(exc),
                    }
                )

        elapsed = time.monotonic() - startTime

        tracked = self.real_objects.setdefault(
            containerName,
            set(),
        )

        tracked.update(successful)

        return self._result(
            action="insert_objects",
            requested=count,
            successful_names=successful,
            failed=failed,
            elapsed=elapsed,
            container=containerName,
            content_prefix=content_prefix,
            object_size=object_size,
        )

    def delete_objects(self, containerName, object_names):
        # Delete specific objects by name using Swift

        self._is_container_owned(containerName)
        names = list(object_names)
        successful = []
        failed = []

        startTime = time.monotonic()
        # Go over all objects and send a delete request
        for objectName in names:
            try:
                self.conn.delete_object(containerName, objectName)
                successful.append(objectName)

            except Exception as exc:
                failed.append(
                    {
                        "name": objectName,
                        "error": repr(exc),
                    }
                )
        elapsed = time.monotonic() - startTime
        # Report success status with error information
        tracked = self.real_objects.setdefault(containerName, set())
        for objectName in successful:
            tracked.discard(objectName)

        return self._result(
            action="delete_objects",
            requested=len(names),
            successful_names=successful,
            failed=failed,
            elapsed=elapsed,
            container=containerName,
        )

    def delete_random_objects(self, containerName, count):
        # Using swift list, randomly select and delete objects.

        self._is_container_owned(containerName)
        if count < 0:
            raise ValueError("count must be >= 0")

        objects = self.list_objects(containerName)

        names = [entry["name"] for entry in objects]

        if count > len(names):
            raise ValueError(
                "Requested deletion of " + str(count) + " objects, "
                "but container contains only " + str(len(names))
            )
        # choose random names by listing then delete
        selected = random.sample(names, count)
        result = self.delete_objects(containerName, selected)

        result["action"] = "delete_random_objects"
        result["selected_names"] = selected

        return result

    def get_object(self, containerName, object_name):
        # Using swift, get object by name
        self._is_container_owned(containerName)

        headers, body = self.conn.get_object(containerName, object_name)

        return headers, body

    def list_objects(self, containerName):
        # Using swift, list object in some container
        self._is_container_owned(containerName)

        _headers, objects = self.conn.get_container(
            containerName,
            full_listing=True,
        )
        return objects

    # ==================================================================
    # Cleanup - container cleanup and full workloader cleanup
    # ==================================================================

    def cleanup_container(self, containerName):
        # Best-effort cleanup of one managed container.
        # workloader will only clean containers owned by it

        self._is_container_owned(containerName)
        startTime = time.monotonic()
        errors = []

        real_deleted = 0
        container_deleted = False
        deleted_names = set()
        tracked = self.real_objects.setdefault(containerName, set())

        # Delete successful uploads by their tracked names first because a
        # sharded listing may be incomplete while replicas converge.
        for objectName in sorted(tracked):
            try:
                self.conn.delete_object(containerName, objectName)
                deleted_names.add(objectName)
                real_deleted += 1

            except ClientException as exc:
                if getattr(exc, "http_status", None) == 404:
                    deleted_names.add(objectName)
                else:
                    errors.append(
                        {
                            "stage": "tracked_objects",
                            "name": objectName,
                            "error": repr(exc),
                        }
                    )

            except Exception as exc:
                errors.append(
                    {
                        "stage": "tracked_objects",
                        "name": objectName,
                        "error": repr(exc),
                    }
                )

        for objectName in deleted_names:
            tracked.discard(objectName)

        # Use a full listing as a fallback for unexpected remaining objects.
        try:
            objects = self.list_objects(containerName)

        except ClientException as exc:
            if getattr(exc, "http_status", None) == 404:
                objects = []
            else:
                errors.append(
                    {
                        "stage": "listing",
                        "error": repr(exc),
                    }
                )

                objects = []

        except Exception as exc:
            errors.append(
                {
                    "stage": "listing",
                    "error": repr(exc),
                }
            )

            objects = []
        # Go over objects and try to delete them
        for entry in objects:
            objectName = entry["name"]

            if objectName in deleted_names:
                continue

            try:
                self.conn.delete_object(containerName, objectName)
                deleted_names.add(objectName)
                tracked.discard(objectName)
                real_deleted += 1

            except ClientException as exc:
                if getattr(exc, "http_status", None) == 404:
                    deleted_names.add(objectName)
                    tracked.discard(objectName)
                else:
                    errors.append(
                        {
                            "stage": "real_objects",
                            "name": objectName,
                            "error": repr(exc),
                        }
                    )

            except Exception as exc:
                errors.append(
                    {
                        "stage": "real_objects",
                        "name": objectName,
                        "error": repr(exc),
                    }
                )

        # Try to delete the container itself
        try:
            self.conn.delete_container(containerName)
            container_deleted = True

        except ClientException as exc:
            if getattr(exc, "http_status", None) == 404:
                container_deleted = True
            else:
                errors.append(
                    {
                        "stage": "container",
                        "error": repr(exc),
                        "http_status": getattr(exc, "http_status", None),
                        "http_reason": getattr(exc, "http_reason", None),
                    }
                )

        except Exception as exc:
            errors.append(
                {
                    "stage": "container",
                    "error": repr(exc),
                }
            )

        if container_deleted:
            self.active_containers.discard(containerName)
            self.real_objects.pop(containerName, None)

        elapsed = time.monotonic() - startTime

        return {
            "action": "container_cleanup",
            "container": containerName,
            "real_objects_deleted": real_deleted,
            "container_deleted": container_deleted,
            "errors": errors,
            "elapsed": elapsed,
            "success": container_deleted and not errors,
        }

    def cleanup(self):
        # Cleanup for each of the containers the workloader owns
        # We will cleanup containers using cleanup_container
        # Runs at the end of a test to verify nothing remains

        startTime = time.monotonic()
        containers = list(self.active_containers)
        results = []

        for containerName in containers:
            try:
                result = self.cleanup_container(containerName)

            except Exception as exc:
                result = {
                    "action": "container_cleanup",
                    "container": containerName,
                    "success": False,
                    "errors": [
                        {
                            "error": repr(exc),
                        }
                    ],
                }
                # Return the error for each container if cleanup fails.

            results.append(result)
        elapsed = time.monotonic() - startTime

        failed = [result for result in results if not result.get("success", False)]

        return {
            "action": "workloader_cleanup",
            "requested": len(containers),
            "successful": len(containers) - len(failed),
            "failed": len(failed),
            "results": results,
            "elapsed": elapsed,
            "success": not failed,
        }
