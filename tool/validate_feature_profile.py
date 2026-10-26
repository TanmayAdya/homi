#!/usr/bin/env python3
"""Check public features against authenticated backend evidence."""
import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
from urllib.parse import urlsplit

FEATURES = {
    'SAFEATHOME_HOME_SAFETY_ENABLED': 'structuredRooms',
    'SAH_TRACKING_ENABLED': 'tracking',
    'SAH_SCAN_SYNC_ENABLED': 'scanSync',
    'SAH_PERMISSION_SHARING_ENABLED': 'permissionSharing',
    'SAH_SENSITIVE_SHARING_ENABLED': 'sensitiveSharing',
    'SAH_SIMPLE_INVITATIONS_ENABLED': 'simpleInvitations',
}
PUBLIC = set(FEATURES) | {
    'SAH_LIVE_BACKEND', 'SAH_LOCAL_HELP_ENABLED', 'SAH_SHARING_LABELS_ENABLED',
    'SAH_EMAIL_DELIVERY_ENABLED', 'SAH_PUBLIC_SIGNUP_ENABLED',
}
READ_ROUTES = {
    '/v3/read-home-safety': 'structuredRoomsContract',
    '/v3/read-progress': 'trackingContract',
    '/v3/read-home-model': 'homeModelContract',
    '/v3/list-sharing': 'permissionSharingContract',
    '/v3/list-email-sharing': 'simpleInvitationsContract',
}
READINESS_BOOLEANS = {
    'authenticated', 'verifiedEmail', 'railwayAuthenticated',
    'temporarySessionCreated', 'temporarySessionClosed',
    'allRequestedReadsAccepted', 'passed', 'sensitiveSharingReadNotProbed',
    *READ_ROUTES.values(),
}
PROVENANCE_FIELDS = {
    'configuration', 'mobile', 'fixture', 'authentication', 'operation',
}
READINESS_FIELDS = READINESS_BOOLEANS | {
    'schemaVersion', 'evidenceKind', 'apiOrigin', 'at', 'finishedAt',
    'provenance', 'configuredFlags', 'routes', 'signInHttpStatus',
    'logoutHttpStatus',
}


def _validate_profile(profile):
    if (not isinstance(profile, dict) or set(profile) != PUBLIC
            or any(type(value) is not bool for value in profile.values())):
        raise ValueError('Profile must contain exactly the documented public boolean controls.')
    if (any(profile[flag] for flag in [
            'SAH_SENSITIVE_SHARING_ENABLED', 'SAH_SIMPLE_INVITATIONS_ENABLED',
            'SAH_SHARING_LABELS_ENABLED'])
            and not profile['SAH_PERMISSION_SHARING_ENABLED']):
        raise ValueError('Detailed sharing/invitations require permission sharing.')
    if profile['SAH_PUBLIC_SIGNUP_ENABLED'] and not profile['SAH_EMAIL_DELIVERY_ENABLED']:
        raise ValueError('Public signup requires separately verified email delivery.')


def _validate_features(profile, features):
    if (not isinstance(features, dict) or set(features) != set(FEATURES.values())
            or any(type(value) is not bool for value in features.values())):
        raise ValueError('Evidence must contain exactly the documented boolean features.')
    for flag, feature in FEATURES.items():
        if profile[flag] and features[feature] is not True:
            raise ValueError(f'{flag} is enabled without selected-backend evidence for {feature}.')


def validate(profile, capabilities):
    """Keep the capability endpoint response contract exact and independent."""
    _validate_profile(profile)
    if (not isinstance(capabilities, dict)
            or set(capabilities) != {'schemaVersion', 'features'}
            or capabilities.get('schemaVersion') != '1'):
        raise ValueError('Authenticated capability evidence is missing or unsupported.')
    _validate_features(profile, capabilities['features'])


def _origin(value):
    if not isinstance(value, str) or not value or value != value.strip():
        raise ValueError('A selected HTTPS API origin is required.')
    try:
        parts = urlsplit(value)
        port = parts.port
    except ValueError:
        raise ValueError('A selected HTTPS API origin is required.') from None
    if (parts.scheme != 'https' or not parts.hostname or parts.username is not None
            or parts.password is not None or parts.path not in ('', '/')
            or parts.query or parts.fragment or any(c.isspace() for c in value)
            or any(ord(c) < 32 for c in value)):
        raise ValueError('A selected HTTPS API origin is required.')
    hostname = parts.hostname.lower()
    if ':' in hostname:
        hostname = f'[{hostname}]'
    return f'https://{hostname}' + (f':{port}' if port not in (None, 443) else '')


def _timestamp(value):
    if not isinstance(value, str):
        raise ValueError('Readiness timestamps must include a timezone.')
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        raise ValueError('Readiness timestamps must include a timezone.') from None
    if parsed.utcoffset() is None:
        raise ValueError('Readiness timestamps must include a timezone.')
    return parsed.astimezone(timezone.utc)


def validate_readiness(profile, readiness, *, api_origin, now=None):
    """Validate current read-probe evidence for the configured service."""
    _validate_profile(profile)
    if (not isinstance(readiness, dict) or set(readiness) != READINESS_FIELDS
            or readiness.get('schemaVersion') != '1'
            or readiness.get('evidenceKind') != 'authenticated-read-probes'):
        raise ValueError('Authenticated read-probe evidence is missing or unsupported.')
    if _origin(readiness['apiOrigin']) != _origin(api_origin):
        raise ValueError('Readiness evidence belongs to a different API origin.')
    provenance = readiness['provenance']
    if (not isinstance(provenance, dict) or set(provenance) != PROVENANCE_FIELDS
            or any(not isinstance(value, str) or not value.strip() or len(value) > 512
                   for value in provenance.values())):
        raise ValueError('Readiness provenance is missing or unsupported.')
    _validate_features(profile, readiness['configuredFlags'])
    if any(readiness[key] is not True for key in READINESS_BOOLEANS):
        raise ValueError('Readiness authentication, contracts, or session cleanup did not pass.')
    if (type(readiness['signInHttpStatus']) is not int or readiness['signInHttpStatus'] != 200
            or type(readiness['logoutHttpStatus']) is not int or readiness['logoutHttpStatus'] != 204):
        raise ValueError('Readiness requires successful sign-in and local session logout.')
    started, finished = _timestamp(readiness['at']), _timestamp(readiness['finishedAt'])
    current = now if now is not None else datetime.now(timezone.utc)
    if (current.utcoffset() is None or not started <= finished <= current
            or current - started > timedelta(hours=24)):
        raise ValueError('Readiness evidence must be completed, not future-dated, and at most 24 hours old.')
    routes = readiness['routes']
    if not isinstance(routes, list) or len(routes) != len(READ_ROUTES):
        raise ValueError('Readiness must contain every required read route exactly once.')
    seen = set()
    for route in routes:
        if (not isinstance(route, dict)
                or set(route) != {'path', 'httpStatus', 'noStore', 'schemaVersion3', 'noError'}
                or not isinstance(route['path'], str) or route['path'] not in READ_ROUTES
                or route['path'] in seen):
            raise ValueError('Readiness must contain every required read route exactly once.')
        seen.add(route['path'])
        if (type(route['httpStatus']) is not int or route['httpStatus'] != 200
                or any(route[key] is not True for key in ['noStore', 'schemaVersion3', 'noError'])):
            raise ValueError('A required read route was unavailable or returned an unsupported response.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', default='config/homi-core.features.json')
    evidence = parser.add_mutually_exclusive_group(required=True)
    evidence.add_argument('--capabilities')
    evidence.add_argument('--readiness')
    parser.add_argument('--config', help='Ignored selected-service configuration; required with --readiness.')
    args = parser.parse_args()
    if args.readiness and not args.config:
        parser.error('--readiness requires --config to verify the selected API origin.')
    try:
        profile = json.loads(Path(args.profile).read_text())
        if args.readiness:
            config = json.loads(Path(args.config).read_text())
            if not isinstance(config, dict):
                raise ValueError('Selected-service configuration is invalid.')
            validate_readiness(profile, json.loads(Path(args.readiness).read_text()),
                               api_origin=config.get('SAH_API_URL'))
        else:
            validate(profile, json.loads(Path(args.capabilities).read_text()))
    except (ValueError, OSError):
        parser.exit(1, 'Profile rejected: check public controls, selected-service evidence, freshness, and session cleanup.\n')
    print('Profile matches supplied backend evidence. Write/export and physical-device acceptance are separate.')


if __name__ == '__main__':
    main()
