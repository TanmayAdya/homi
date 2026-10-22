#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash tool/verify_project.sh [flutter|backend|all] [options]

Scopes (default: all):
  flutter   Check Dart formatting, Flutter analysis/tests, and tracked diff whitespace.
  backend   Check TypeScript types, Node tests, shared fixtures, and diff whitespace.
  all       Run both scopes plus real Dart-to-HTTP matching, answers, export, case/photo, discovery and manual request-history checks.

Options:
  --backend PATH     Backend package directory containing package.json.
                     Default: app/backend, then ../safe-at-home-backend/backend.
  --flutter COMMAND  Flutter executable name or path; default: flutter on PATH.
                     Dart is taken from the same bin directory.
  -h, --help         Show this help without running checks.

Relative option paths are resolved from the directory where you invoke this script.
The app directory is determined from this script's location. Dependencies must
already be resolved; no packages are installed or upgraded and no files are fixed.
Git commands only inspect diffs. Platform builds, coverage measurement, and
security/manual code review remain separate checks.
USAGE
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit "${2:-1}"
}

scope=all
scope_set=false
backend_option=
flutter_option=flutter

while [[ $# -gt 0 ]]; do
  case "$1" in
    flutter|backend|all)
      [[ "$scope_set" == false ]] || fail 'Specify only one scope.' 2
      scope=$1
      scope_set=true
      shift
      ;;
    --backend|--flutter)
      option=$1
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || fail "$option requires a value." 2
      if [[ "$option" == --backend ]]; then
        backend_option=$2
      else
        flutter_option=$2
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1. Use --help for usage." 2
      ;;
  esac
done

app_dir=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
fixtures="$app_dir/contracts/v1/fixtures/scenarios.json"

resolve_executable() {
  local requested=$1
  local resolved
  if [[ "$requested" == */* ]]; then
    resolved=$requested
  else
    resolved=$(command -v "$requested") || fail "Required executable not found: $requested."
  fi
  [[ -x "$resolved" && ! -d "$resolved" ]] || fail "Not an executable file: $resolved."
  printf '%s/%s\n' "$(cd -- "$(dirname "$resolved")" && pwd -P)" "$(basename "$resolved")"
}

require_file() {
  [[ -f "$1" ]] || fail "$2 Missing: $1"
}

run_check() {
  local label=$1
  local directory=$2
  local status
  shift 2
  printf '\nChecking %s...\n' "$label"
  if (cd -- "$directory" && "$@"); then
    printf 'PASS: %s\n' "$label"
  else
    status=$?
    printf 'FAIL: %s (exit %s)\n' "$label" "$status" >&2
    exit "$status"
  fi
}

git_bin=$(resolve_executable git)
"$git_bin" -C "$app_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "The app directory is not a Git checkout: $app_dir."

if [[ "$scope" == flutter || "$scope" == all ]]; then
  flutter_bin=$(resolve_executable "$flutter_option")
  dart_bin="$(dirname "$flutter_bin")/dart"
  [[ -x "$dart_bin" && ! -d "$dart_bin" ]] ||
    fail "Dart was not found beside Flutter. Pass --flutter with the Flutter SDK's bin/flutter path."
  require_file "$app_dir/pubspec.yaml" 'The Flutter app is unavailable.'
  require_file "$app_dir/.dart_tool/package_config.json" \
    'Flutter dependencies are unresolved. Resolve them separately before verifying.'
fi

if [[ "$scope" == backend || "$scope" == all ]]; then
  if [[ -n "$backend_option" ]]; then
    backend_dir=$backend_option
  elif [[ -f "$app_dir/backend/package.json" ]]; then
    backend_dir="$app_dir/backend"
  else
    backend_dir="$app_dir/../safe-at-home-backend/backend"
  fi
  [[ -d "$backend_dir" ]] || fail 'Backend directory not found. Pass --backend PATH.'
  backend_dir=$(cd -- "$backend_dir" && pwd -P)
  require_file "$backend_dir/package.json" 'The backend package is unavailable.'
  require_file "$fixtures" 'The shared contract fixtures are unavailable.'
  require_file "$backend_dir/node_modules/typescript/bin/tsc" \
    'Backend development dependencies are unresolved. Resolve them separately before verifying.'
  require_file "$backend_dir/node_modules/@types/node/package.json" \
    'Backend Node declarations are unresolved. Resolve dependencies separately before verifying.'
  [[ -x "$backend_dir/node_modules/.bin/tsc" ]] ||
    fail 'The local TypeScript executable is missing. Repair backend dependencies separately.'
  node_bin=$(resolve_executable node)
  npm_bin=$(resolve_executable npm)
  "$node_bin" -e '
    const [major, minor] = process.versions.node.split(".").map(Number);
    if (major < 24 || (major === 24 && minor < 12)) {
      console.error("Node >=24.12.0 is required; found " + process.versions.node + ".");
      process.exit(1);
    }
  ' || fail 'Use a supported Node version before verifying the backend.'
  "$git_bin" -C "$backend_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    fail "The backend directory is not inside a Git checkout: $backend_dir."
fi

if [[ "$scope" == all ]]; then
  require_file "$app_dir/tool/check_matching_api.dart" 'The Dart HTTP integration check is unavailable.'
  require_file "$app_dir/tool/check_form_answers_api.dart" 'The reviewed-answer HTTP integration check is unavailable.'
  require_file "$app_dir/tool/check_draft_export_api.dart" 'The private draft export integration check is unavailable.'
  require_file "$app_dir/tool/check_case_evidence_api.dart" 'The case/photo write integration check is unavailable.'
  require_file "$app_dir/tool/check_case_discovery_api.dart" 'The case discovery/resume integration check is unavailable.'
  require_file "$app_dir/tool/check_request_tracking_api.dart" 'The manual request-history integration check is unavailable.'
  require_file "$backend_dir/src/api/demo-server.ts" 'The local HTTP demo server is unavailable.'
fi

if [[ "$scope" == flutter || "$scope" == all ]]; then
  run_check 'Dart formatting (read-only)' "$app_dir" \
    "$dart_bin" format --output=none --set-exit-if-changed lib test tool
  run_check 'Flutter analysis' "$app_dir" "$flutter_bin" analyze --no-pub
  run_check 'Flutter tests' "$app_dir" "$flutter_bin" test --no-pub
  run_check 'App tracked diff whitespace' "$app_dir" "$git_bin" diff --check HEAD
fi

if [[ "$scope" == backend || "$scope" == all ]]; then
  run_check 'Backend TypeScript types' "$backend_dir" "$npm_bin" run typecheck
  run_check 'Backend Node tests' "$backend_dir" "$npm_bin" test
  run_check 'Backend shared contract fixtures' "$backend_dir" \
    "$npm_bin" run test:contracts -- "$fixtures"
  run_check 'Backend tracked diff whitespace' "$backend_dir" "$git_bin" diff --check HEAD
fi

if [[ "$scope" == all ]]; then
  run_check 'Dart-to-HTTP matching integration' "$app_dir" \
    "$dart_bin" --packages="$app_dir/.dart_tool/package_config.json" \
    "$app_dir/tool/check_matching_api.dart" --backend "$backend_dir"
  run_check 'Dart-to-HTTP reviewed answers integration' "$app_dir" \
    "$dart_bin" --packages="$app_dir/.dart_tool/package_config.json" \
    "$app_dir/tool/check_form_answers_api.dart" --backend "$backend_dir"
  run_check 'Dart-to-HTTP private draft export integration' "$app_dir" \
    "$dart_bin" --packages="$app_dir/.dart_tool/package_config.json" \
    "$app_dir/tool/check_draft_export_api.dart" --backend "$backend_dir"
  run_check 'Dart-to-HTTP case and photo writes integration' "$app_dir" \
    "$dart_bin" --packages="$app_dir/.dart_tool/package_config.json" \
    "$app_dir/tool/check_case_evidence_api.dart" --backend "$backend_dir"
  run_check 'Dart-to-HTTP case discovery and resume integration' "$app_dir" \
    "$dart_bin" --packages="$app_dir/.dart_tool/package_config.json" \
    "$app_dir/tool/check_case_discovery_api.dart" --backend "$backend_dir"
  run_check 'Dart-to-HTTP manual request history integration' "$app_dir" \
    "$dart_bin" --packages="$app_dir/.dart_tool/package_config.json" \
    "$app_dir/tool/check_request_tracking_api.dart" --backend "$backend_dir"
fi

printf '\nPASS: all checks selected by scope "%s" completed.\n' "$scope"
printf 'Platform builds, coverage measurement, and security/manual review were not run.\n'
