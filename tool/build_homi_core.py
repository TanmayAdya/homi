#!/usr/bin/env python3
"""Build with verified features and an ignored private configuration."""
import argparse
import json
import subprocess
from pathlib import Path
from validate_feature_profile import validate, validate_readiness


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    evidence = parser.add_mutually_exclusive_group(required=True)
    evidence.add_argument('--capabilities')
    evidence.add_argument('--readiness')
    parser.add_argument('--platform', choices=['ios', 'apk', 'appbundle'], required=True)
    parser.add_argument('--flutter', default='flutter')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    profile = root / 'config/homi-core.features.json'
    private = Path(args.config).resolve()
    try:
        if not private.is_file():
            raise ValueError('Private configuration file is missing.')
        ignored = subprocess.run(['git', 'check-ignore', '--quiet', str(private)], cwd=root, check=False)
        if ignored.returncode != 0:
            raise ValueError('Private configuration must be in an ignored path.')
        public = json.loads(profile.read_text())
        if args.readiness:
            config = json.loads(private.read_text())
            if not isinstance(config, dict):
                raise ValueError('Private configuration is invalid.')
            validate_readiness(public, json.loads(Path(args.readiness).read_text()),
                               api_origin=config.get('SAH_API_URL'))
        else:
            validate(public, json.loads(Path(args.capabilities).read_text()))
    except (ValueError, OSError):
        parser.exit(1, 'Build rejected: check ignored configuration and selected-service evidence with validate_feature_profile.py.\n')
    return subprocess.call([
        args.flutter, 'build', args.platform, '--no-pub',
        f'--dart-define-from-file={private}', f'--dart-define-from-file={profile}',
    ], cwd=root)


if __name__ == '__main__':
    raise SystemExit(main())
