from copy import deepcopy
from datetime import datetime, timedelta, timezone
from contextlib import redirect_stderr
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_homi_core
from validate_feature_profile import (
    FEATURES, PROVENANCE_FIELDS, READINESS_BOOLEANS, READ_ROUTES,
    validate, validate_readiness,
)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.profile = json.loads((Path(__file__).parent.parent / 'config/homi-core.features.json').read_text())
        self.evidence = {'schemaVersion': '1', 'features': {key: True for key in FEATURES.values()}}
        self.now = datetime.now(timezone.utc)
        self.origin = 'https://fictional-api.example.org'
        self.readiness = {
            'schemaVersion': '1', 'evidenceKind': 'authenticated-read-probes',
            'apiOrigin': self.origin,
            'at': (self.now - timedelta(minutes=2)).isoformat(),
            'finishedAt': (self.now - timedelta(minutes=1)).isoformat(),
            'provenance': {key: 'Fictional test evidence only' for key in PROVENANCE_FIELDS},
            'configuredFlags': deepcopy(self.evidence['features']),
            'routes': [
                {'path': path, 'httpStatus': 200, 'noStore': True,
                 'schemaVersion3': True, 'noError': True}
                for path in READ_ROUTES
            ],
            **{key: True for key in READINESS_BOOLEANS},
            'signInHttpStatus': 200, 'logoutHttpStatus': 204,
        }

    def check_readiness(self, value=None, *, origin=None):
        validate_readiness(self.profile, self.readiness if value is None else value,
                           api_origin=self.origin if origin is None else origin, now=self.now)

    def test_profile_enables_audited_features_without_email_or_signup(self):
        self.assertTrue(all(self.profile[key] for key in FEATURES))
        self.assertTrue(self.profile['SAH_LOCAL_HELP_ENABLED'])
        self.assertFalse(self.profile['SAH_EMAIL_DELIVERY_ENABLED'])
        self.assertFalse(self.profile['SAH_PUBLIC_SIGNUP_ENABLED'])

        self.assertFalse(self.profile['SAH_SHARING_LABELS_ENABLED'])

    def test_strict_capability_response_still_accepted(self):
        validate(self.profile, self.evidence)

    def test_each_disabled_backend_feature_rejected_in_both_modes(self):
        for feature in FEATURES.values():
            with self.subTest(feature=feature):
                evidence = deepcopy(self.evidence)
                evidence['features'][feature] = False
                with self.assertRaises(ValueError):
                    validate(self.profile, evidence)
                readiness = deepcopy(self.readiness)
                readiness['configuredFlags'][feature] = False
                with self.assertRaises(ValueError):
                    self.check_readiness(readiness)

    def test_unknown_public_controls_and_nonboolean_flags_rejected(self):
        for key, value in [('PRIVATE_KEY', 'must-not-print'), ('SAH_SCAN_SYNC_ENABLED', 1)]:
            profile = {**self.profile, key: value}
            with self.assertRaises(ValueError):
                validate(profile, self.evidence)
            with self.assertRaises(ValueError):
                validate_readiness(profile, self.readiness, api_origin=self.origin, now=self.now)

    def test_sharing_and_signup_dependencies_preserved(self):
        for change in [
            {'SAH_PERMISSION_SHARING_ENABLED': False},
            {'SAH_PERMISSION_SHARING_ENABLED': False, 'SAH_SIMPLE_INVITATIONS_ENABLED': False,
             'SAH_SENSITIVE_SHARING_ENABLED': False, 'SAH_SHARING_LABELS_ENABLED': True},
            {'SAH_PUBLIC_SIGNUP_ENABLED': True},
        ]:
            profile = {**self.profile, **change}
            with self.assertRaises(ValueError):
                validate(profile, self.evidence)
            with self.assertRaises(ValueError):
                validate_readiness(profile, self.readiness, api_origin=self.origin, now=self.now)

    def test_capabilities_404_and_readiness_cannot_be_capability_responses(self):
        for evidence in [None, [], {}, {'status': 404}, self.readiness,
                         {'schemaVersion': '1', 'features': self.evidence['features'], 'extra': True}]:
            with self.subTest(evidence_type=type(evidence).__name__):
                with self.assertRaises(ValueError):
                    validate(self.profile, evidence)

    def test_features_require_exact_six_boolean_fields(self):
        for features in [None, [], {'structuredRooms': True},
                         {**self.evidence['features'], 'unknown': True},
                         {**self.evidence['features'], 'scanSync': 1},
                         {**self.evidence['features'], 'scanSync': 'true'}]:
            with self.assertRaises(ValueError):
                validate(self.profile, {'schemaVersion': '1', 'features': features})
            readiness = {**self.readiness, 'configuredFlags': features}
            with self.assertRaises(ValueError):
                self.check_readiness(readiness)

    def test_fresh_readiness_accepts_same_normalized_origin(self):
        self.check_readiness()
        self.check_readiness(origin='https://FICTIONAL-API.EXAMPLE.ORG:443/')

    def test_report_shape_and_evidence_kind_are_explicit(self):
        for value in [None, [], self.evidence, {'status': 404},
                      {**self.readiness, 'evidenceKind': 'capabilities'},
                      {**self.readiness, 'schemaVersion': '2'},
                      {**self.readiness, 'unexpected': 'not-allowed'}]:
            with self.assertRaises(ValueError):
                validate_readiness(self.profile, value, api_origin=self.origin, now=self.now)

    def test_every_auth_contract_and_cleanup_boolean_must_be_true(self):
        for key in READINESS_BOOLEANS:
            for value in [False, 1, 'true', None]:
                with self.subTest(key=key, value=value):
                    with self.assertRaises(ValueError):
                        self.check_readiness({**self.readiness, key: value})
            missing = deepcopy(self.readiness)
            del missing[key]
            with self.assertRaises(ValueError):
                self.check_readiness(missing)

    def test_signin_and_logout_status_must_match_success(self):
        for key, value in [('signInHttpStatus', 401), ('signInHttpStatus', True),
                           ('logoutHttpStatus', 200), ('logoutHttpStatus', '204')]:
            with self.assertRaises(ValueError):
                self.check_readiness({**self.readiness, key: value})

    def test_provenance_required_without_unknown_or_private_fields(self):
        for provenance in [{}, [], None, {**self.readiness['provenance'], 'token': 'not-allowed'},
                           {**self.readiness['provenance'], 'configuration': ''}]:
            with self.assertRaises(ValueError):
                self.check_readiness({**self.readiness, 'provenance': provenance})

    def test_readiness_must_match_selected_https_api_origin(self):
        for origin in ['https://another.example.org', 'http://fictional-api.example.org',
                       'https://fictional-api.example.org/private',
                       'https://secret@fictional-api.example.org',
                       'https://fictional-api.example.org?token=private',
                       'https://fictional-api.example.org#fragment',
                       'https://fictional-api.example.org:invalid', '', None]:
            with self.subTest(origin=origin):
                with self.assertRaises(ValueError):
                    validate_readiness(self.profile, self.readiness, api_origin=origin, now=self.now)
        with self.assertRaises(ValueError):
            self.check_readiness({**self.readiness, 'apiOrigin': 'https://another.example.org'})

    def test_stale_future_reversed_and_timezone_less_evidence_rejected(self):
        timestamps = [
            {'at': (self.now - timedelta(hours=24, seconds=1)).isoformat()},
            {'finishedAt': (self.now + timedelta(seconds=1)).isoformat()},
            {'at': self.now.isoformat()},
            {'at': '2026-10-26T11:18:45'},
            {'finishedAt': 'not a timestamp'},
            {'at': None},
        ]
        for times in timestamps:
            with self.subTest(times=times):
                with self.assertRaises(ValueError):
                    self.check_readiness({**self.readiness, **times})
        self.check_readiness({**self.readiness, 'at': (self.now - timedelta(hours=24)).isoformat()})

    def test_missing_duplicate_unknown_and_malformed_routes_rejected(self):
        routes = self.readiness['routes']
        for value in [None, {}, routes[:-1], routes + [routes[0]],
                      [routes[0]] * len(routes),
                      [{**routes[0], 'path': '/v1/capabilities'}, *routes[1:]],
                      [{**routes[0], 'privatePayload': {}}, *routes[1:]],
                      [None, *routes[1:]]]:
            with self.assertRaises(ValueError):
                self.check_readiness({**self.readiness, 'routes': value})

    def test_each_route_requires_200_no_store_schema_and_no_error(self):
        for index in range(len(READ_ROUTES)):
            for key, value in [('httpStatus', 404), ('httpStatus', 401), ('httpStatus', '200'),
                               ('noStore', False), ('schemaVersion3', False), ('noError', False),
                               ('noStore', 1)]:
                readiness = deepcopy(self.readiness)
                readiness['routes'][index][key] = value
                with self.subTest(index=index, key=key, value=value):
                    with self.assertRaises(ValueError):
                        self.check_readiness(readiness)

    def run_builder(self, directory, *, mode='readiness', evidence=None, ignored=True, both=False):
        private = directory / 'private.json'
        private.write_text(json.dumps({'SAH_API_URL': self.origin, 'SUPABASE_PUBLISHABLE_KEY': 'private-test-value'}))
        proof = directory / 'evidence.json'
        proof.write_text(json.dumps(evidence if evidence is not None else
                                    self.readiness if mode == 'readiness' else self.evidence))
        arguments = ['build_homi_core.py', '--platform', 'ios', '--config', str(private),
                     '--' + mode, str(proof), '--flutter', 'must-not-execute-flutter']
        if both:
            arguments += ['--capabilities', str(proof)]
        with patch('sys.argv', arguments), patch('build_homi_core.subprocess.run') as run, \
                patch('build_homi_core.subprocess.call') as call, redirect_stderr(io.StringIO()) as output:
            run.return_value.returncode = 0 if ignored else 1
            call.return_value = 0
            try:
                status = build_homi_core.main()
            except SystemExit as error:
                status = error.code
            return status, call.call_args_list, output.getvalue()

    def test_builder_validates_both_explicit_modes_before_flutter(self):
        with tempfile.TemporaryDirectory() as directory:
            for mode in ['readiness', 'capabilities']:
                status, calls, _ = self.run_builder(Path(directory), mode=mode)
                self.assertEqual(status, 0)
                self.assertEqual(len(calls), 1)
                arguments = calls[0].args[0]
                self.assertEqual(arguments[:4], ['must-not-execute-flutter', 'build', 'ios', '--no-pub'])
                self.assertTrue(arguments[-1].endswith('/config/homi-core.features.json'))

    def test_builder_rejects_mismatch_stale_ambiguous_or_nonignored_inputs(self):
        variants = [
            {'evidence': {**self.readiness, 'apiOrigin': 'https://wrong.example.org'}},
            {'evidence': {**self.readiness, 'at': (self.now - timedelta(days=2)).isoformat()}},
            {'evidence': {**self.readiness, 'temporarySessionClosed': False}},
            {'ignored': False}, {'both': True},
        ]
        with tempfile.TemporaryDirectory() as directory:
            for options in variants:
                status, calls, output = self.run_builder(Path(directory), **options)
                self.assertNotEqual(status, 0)
                self.assertEqual(calls, [])
                self.assertNotIn('private-test-value', output)
                self.assertNotIn(self.origin, output)


if __name__ == '__main__':
    unittest.main()
