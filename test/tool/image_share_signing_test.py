import copy
import importlib.util
import pathlib
import unittest

script = pathlib.Path(__file__).resolve().parents[2] / "tool/verify_ios_image_share_signing.py"
spec = importlib.util.spec_from_file_location("image_share_signing", script)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class SigningPolicyTests(unittest.TestCase):
    def test_each_target_requires_group_in_signature_and_profile(self):
        for bundle in (policy.APP_ID, policy.APP_ID + ".ShareExtension"):
            signed = {"application-identifier": "TEAM." + bundle,
                      "com.apple.security.application-groups": [policy.GROUP]}
            policy.validate_entitlements(signed, copy.deepcopy(signed), bundle)
            for missing in ("signature", "profile"):
                signature, profile = copy.deepcopy(signed), copy.deepcopy(signed)
                (signature if missing == "signature" else profile).pop("com.apple.security.application-groups")
                with self.subTest(bundle=bundle, missing=missing), self.assertRaises(ValueError):
                    policy.validate_entitlements(signature, profile, bundle)

    def test_rejects_wrong_bundle_or_profile(self):
        signed = {"application-identifier": "TEAM." + policy.APP_ID,
                  "com.apple.security.application-groups": [policy.GROUP]}
        with self.assertRaises(ValueError):
            policy.validate_entitlements(signed, signed, policy.APP_ID + ".ShareExtension")
        profile = {**signed, "application-identifier": "OTHER." + policy.APP_ID}
        with self.assertRaises(ValueError):
            policy.validate_entitlements(signed, profile, policy.APP_ID)


if __name__ == "__main__":
    unittest.main()
