# Host side verification of the sharding threshold change

import unittest

from probe.set_sharding_threshold import (
    inspect_live_profile,
    set_sharding_profile,
    set_sharding_threshold,
    verify_live_settings,
)


# In order to verify sharding works according to the new profile,
# We will change and test the threshold to the following values
FIRST_THRESHOLD = 100
SECOND_THRESHOLD = 50
SHRINK_THRESHOLD = 10


def _flatten_profile(observed):
    # Confirm all inspected profiles converage to a single one
    # When values are different between profiles, will raise an error
    profile = {}
    for name, values_by_path in observed.items():
        values = set(values_by_path.values())
        if len(values) != 1:
            raise AssertionError("inconsistent values for " + name)
        value = values.pop()
        if value:
            profile[name] = value
    return profile


def _profile_summary(profile):
    """Render the important profile values on one compact output line."""
    names = (
        "auto_shard",
        "shard_container_threshold",
        "rows_per_shard",
        "minimum_shard_size",
        "shrink_threshold",
        "shard_scanner_batch_size",
        "cleave_batch_size",
    )
    return ", ".join(
        name + "=" + str(profile[name]) for name in names if name in profile
    )


class TestShardingProfile(unittest.TestCase):
    def test_threshold_and_profile_changes(self):
        # Saves the original profile to reinstate it at the end.
        original_profile = _flatten_profile(inspect_live_profile(verbose=False))
        print(
            "PROFILE: original profile captured: "
            + _profile_summary(original_profile),
            flush=True,
        )
        try:
            print(
                "PROFILE STAGE 1: applying threshold profile: "
                + str(FIRST_THRESHOLD),
                flush=True,
            )
            set_sharding_threshold(FIRST_THRESHOLD, restart_all=False)
            verify_live_settings({
                "auto_shard": "true",
                "shard_container_threshold": str(FIRST_THRESHOLD),
            })
            print(
                "PROFILE STAGE 1: verified threshold profile: auto_shard=true, "
                + "shard_container_threshold="
                + str(FIRST_THRESHOLD),
                flush=True,
            )

            profile = {
                "auto_shard": "true",
                "shard_container_threshold": str(SECOND_THRESHOLD),
                "rows_per_shard": str(SECOND_THRESHOLD // 2),
                "minimum_shard_size": str(max(
                    1, SECOND_THRESHOLD // 10, SHRINK_THRESHOLD
                )),
                "shrink_threshold": str(SHRINK_THRESHOLD),
                "shard_scanner_batch_size": "10",
                "cleave_batch_size": "2",
            }
            print(
                "PROFILE STAGE 2: applying complete profile: "
                + _profile_summary(profile),
                flush=True,
            )
            set_sharding_profile(profile, restart_all=False)
            verify_live_settings(profile)
            observed = inspect_live_profile(verbose=False)
            self.assertEqual(
                observed["shard_container_threshold"][
                    "/etc/swift/container-server/container-server.conf"
                ],
                str(SECOND_THRESHOLD),
            )
            self.assertEqual(
                observed["shrink_threshold"][
                    "/etc/swift/container-server/container-server.conf"
                ],
                str(SHRINK_THRESHOLD),
            )
            print(
                "PROFILE STAGE 2: verified complete profile is active",
                flush=True,
            )

            print(
                "PROFILE STAGE 3: reapplying the same profile to verify idempotence",
                flush=True,
            )
            set_sharding_profile(profile, restart_all=False)
            verify_live_settings(profile)
            print("PROFILE STAGE 3: idempotence verified", flush=True)
        finally:
            print(
                "PROFILE RESTORE: returning to original profile: "
                + _profile_summary(original_profile),
                flush=True,
            )
            set_sharding_profile(original_profile, restart_all=False)
            verify_live_settings(original_profile)
            print("PROFILE RESTORE: original profile verified", flush=True)


if __name__ == "__main__":
    unittest.main()
