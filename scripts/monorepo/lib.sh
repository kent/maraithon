#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPANION_DIR="${ROOT_DIR}/apps/companion"
MOBILE_DIR="${ROOT_DIR}/apps/mobile"
COMPANION_BUNDLE_ID="com.maraithon.companion"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

validate_component() {
  local component="${1:-all}"
  shift || true
  local allowed=("$@")

  for value in "${allowed[@]}"; do
    if [[ "${component}" == "${value}" ]]; then
      return
    fi
  done

  echo "Unknown component: ${component}" >&2
  echo "Expected one of: ${allowed[*]}" >&2
  exit 64
}

require_command() {
  local name="$1"

  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "Missing required command: ${name}" >&2
    exit 1
  fi
}

run_in() {
  local dir="$1"
  shift

  echo
  echo "==> ${dir#$ROOT_DIR/}: $*"
  (cd "${dir}" && "$@")
}

selected_component() {
  local requested="${1:-all}"
  local component="$2"

  case "${requested}" in
    api)
      requested="web"
      ;;
    ios)
      requested="mobile"
      ;;
    mac)
      requested="companion"
      ;;
  esac

  [[ "${requested}" == "all" || "${requested}" == "${component}" || "${requested}" == "native" && "${component}" != "web" ]]
}

generate_xcode_project() {
  local dir="$1"

  require_command xcodegen
  run_in "${dir}" xcodegen generate
}

companion_project_generation_fingerprint() {
  (
    cd "${COMPANION_DIR}"
    {
      shasum project.yml Package.swift Package.resolved
      find Sources Tests -type f -print | LC_ALL=C sort
    } | shasum | awk '{print $1}'
  )
}

ensure_companion_xcode_project() {
  local project_file="${COMPANION_DIR}/Maraithon.xcodeproj/project.pbxproj"
  local marker_file="${COMPANION_DIR}/Maraithon.xcodeproj/.maraithon-input-fingerprint"
  local current_fingerprint previous_fingerprint

  current_fingerprint="$(companion_project_generation_fingerprint)"
  previous_fingerprint="$(cat "${marker_file}" 2>/dev/null || true)"

  if [[ -f "${project_file}" && "${current_fingerprint}" == "${previous_fingerprint}" ]]; then
    echo "Using current companion Xcode project."
    return
  fi

  generate_xcode_project "${COMPANION_DIR}"
  printf '%s\n' "${current_fingerprint}" > "${marker_file}"
}

companion_xcode_signing_args() {
  local config="${COMPANION_DIR}/Config.local.xcconfig"

  if ! companion_has_persistent_signing_config; then
    # A completely unsigned .app can build successfully but macOS kills it
    # at launch with "Taskgated Invalid Signature". Fresh clones should still
    # produce a launchable Debug bundle, so fall back to ad-hoc signing.
    printf '%s\n' "CODE_SIGN_STYLE=Manual"
    printf '%s\n' "CODE_SIGN_IDENTITY=-"
    printf '%s\n' "CODE_SIGNING_ALLOWED=YES"
    return
  fi

  local style identity team
  style="$(xcconfig_value "${config}" CODE_SIGN_STYLE)"
  identity="$(xcconfig_value "${config}" CODE_SIGN_IDENTITY)"
  team="$(xcconfig_value "${config}" DEVELOPMENT_TEAM)"

  if [[ -n "${style}" ]]; then
    printf '%s\n' "CODE_SIGN_STYLE=${style}"
  fi
  if [[ -n "${identity}" ]]; then
    printf '%s\n' "CODE_SIGN_IDENTITY=${identity}"
  fi
  if [[ -n "${team}" ]]; then
    printf '%s\n' "DEVELOPMENT_TEAM=${team}"
  fi
}

companion_has_persistent_signing_config() {
  local config="${COMPANION_DIR}/Config.local.xcconfig"
  local identity

  [[ -f "${config}" ]] || return 1

  identity="$(xcconfig_value "${config}" CODE_SIGN_IDENTITY)"
  [[ -n "${identity}" && "${identity}" != "-" ]]
}

ensure_companion_dev_signing() {
  if [[ "${MARAITHON_COMPANION_SKIP_SIGNING_SETUP:-}" == "1" ]]; then
    echo "Skipping companion signing setup; Full Disk Access may not persist across reloads." >&2
    return
  fi

  if companion_has_persistent_signing_config; then
    echo "Verifying companion signing pin for persistent Full Disk Access..."
  else
    echo "Configuring stable companion signing so macOS privacy grants persist across reloads..."
  fi
  "${COMPANION_DIR}/scripts/create_dev_signing_identity.sh"
}

xcconfig_value() {
  local config="$1"
  local key="$2"

  awk -F= -v key="${key}" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      value = $0
      sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "${config}"
}

companion_debug_app_path() {
  local show_build_settings_args=(
    -project Maraithon.xcodeproj
    -scheme Maraithon
    -configuration Debug
  )
  if [[ -n "${MARAITHON_COMPANION_DERIVED_DATA_PATH:-}" ]]; then
    show_build_settings_args+=(-derivedDataPath "${MARAITHON_COMPANION_DERIVED_DATA_PATH}")
  fi
  if [[ -n "${MARAITHON_COMPANION_CONFIGURATION_BUILD_DIR:-}" ]]; then
    show_build_settings_args+=("CONFIGURATION_BUILD_DIR=${MARAITHON_COMPANION_CONFIGURATION_BUILD_DIR}")
  fi

  local build_dir
  build_dir="$(
    cd "${COMPANION_DIR}" &&
      xcodebuild \
        "${show_build_settings_args[@]}" \
        -showBuildSettings 2>/dev/null |
      awk -F= '
        $1 ~ /BUILT_PRODUCTS_DIR[[:space:]]*$/ {
          value = $2
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          print value
          exit
        }
      '
  )"

  if [[ -z "${build_dir}" ]]; then
    echo "Unable to locate companion Debug build products." >&2
    exit 1
  fi

  printf '%s\n' "${build_dir}/Maraithon.app"
}

verify_companion_app_signature() {
  local app_path="$1"

  if [[ ! -d "${app_path}" ]]; then
    echo "Companion app was not built at ${app_path}" >&2
    exit 1
  fi

  if ! codesign --verify --deep --strict --verbose=2 "${app_path}"; then
    echo "Companion app has an invalid code signature: ${app_path}" >&2
    echo "Run make setup-companion-signing for stable local signing, or rebuild with the ad-hoc fallback." >&2
    exit 1
  fi
}

quit_running_companion_app() {
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'tell application id "com.maraithon.companion" to quit' >/dev/null 2>&1 || true
  fi

  for _ in {1..4}; do
    if ! pgrep -x Maraithon >/dev/null 2>&1; then
      return
    fi
    sleep 0.25
  done

  pkill -TERM -x Maraithon >/dev/null 2>&1 || true
  for _ in {1..8}; do
    if ! pgrep -x Maraithon >/dev/null 2>&1; then
      return
    fi
    sleep 0.25
  done

  pkill -KILL -x Maraithon >/dev/null 2>&1 || true
}

install_companion_dev_app() {
  local built_app="$1"
  local install_app="$2"

  if [[ "${built_app%/}" == "${install_app%/}" ]]; then
    return
  fi

  mkdir -p "$(dirname "${install_app}")"

  if [[ -d "${install_app}" ]]; then
    require_command rsync
    # Preserve the existing bundle and file identities as much as possible:
    # macOS privacy grants can be sensitive to dev app replacement even when
    # the bundle identifier and signing requirement stay the same.
    rsync -a --delete --inplace "${built_app}/" "${install_app}/"
    return
  fi

  if [[ -e "${install_app}" ]]; then
    rm -rf "${install_app}"
  fi

  ditto "${built_app}" "${install_app}"
}

cleanup_companion_direct_build_products() {
  local build_dir="$1"
  local keep_app="$2"

  case "${build_dir}" in
    "" | "/" | "${HOME}")
      echo "Refusing to clean companion build products from unsafe directory: ${build_dir}" >&2
      return 1
      ;;
  esac

  local product_names=(
    "AsyncAlgorithms.appintents"
    "AsyncAlgorithms.o"
    "AsyncAlgorithms.swiftmodule"
    "Autoupdate.dSYM"
    "ContainersPreview.appintents"
    "ContainersPreview.o"
    "ContainersPreview.swiftmodule"
    "DequeModule.appintents"
    "DequeModule.o"
    "DequeModule.swiftmodule"
    "Downloader.xpc.dSYM"
    "Installer.xpc.dSYM"
    "InternalCollectionsUtilities.appintents"
    "InternalCollectionsUtilities.o"
    "InternalCollectionsUtilities.swiftmodule"
    "Maraithon.appintents"
    "Maraithon.swiftmodule"
    "OrderedCollections.appintents"
    "OrderedCollections.o"
    "OrderedCollections.swiftmodule"
    "PackageFrameworks"
    "Sparkle.framework"
    "Sparkle.framework.dSYM"
    "Updater.app.dSYM"
    "include"
  )

  local product_path
  for product_name in "${product_names[@]}"; do
    product_path="${build_dir}/${product_name}"
    if [[ "${product_path%/}" == "${keep_app%/}" ]]; then
      continue
    fi
    if [[ -e "${product_path}" ]]; then
      rm -rf "${product_path}"
    fi
  done
}

companion_designated_requirement() {
  local app_path="$1"

  codesign -dr - "${app_path}" 2>&1 | sed -n 's/^designated => //p'
}

companion_tcc_marker_path() {
  printf '%s\n' "${HOME}/Library/Application Support/Maraithon/companion-dev-designated-requirement.txt"
}

read_companion_tcc_marker() {
  local marker_path="$1"
  local marker_header previous_version previous_requirement

  marker_header="$(head -n 1 "${marker_path}" 2>/dev/null || true)"
  case "${marker_header}" in
    tcc-requirement-version=* | tcc-reset-version=*)
      previous_version="${marker_header#*=}"
      previous_requirement="$(tail -n +2 "${marker_path}" 2>/dev/null || true)"
      ;;
    *)
      previous_version=""
      previous_requirement="$(cat "${marker_path}" 2>/dev/null || true)"
      ;;
  esac

  printf '%s\n%s\n' "${previous_version}" "${previous_requirement}"
}

write_companion_tcc_marker() {
  local marker_path="$1"
  local marker_version="$2"
  local requirement="$3"

  mkdir -p "$(dirname "${marker_path}")"
  {
    printf 'tcc-requirement-version=%s\n' "${marker_version}"
    printf '%s\n' "${requirement}"
  } > "${marker_path}"
}

record_companion_tcc_requirement() {
  local app_path="$1"
  local marker_path
  local requirement previous_requirement previous_marker_version
  local marker_version="4"

  requirement="$(companion_designated_requirement "${app_path}")"
  if [[ -z "${requirement}" ]]; then
    echo "Unable to read companion code-signing requirement; Full Disk Access may not persist." >&2
    return
  fi

  if [[ "${requirement}" == cdhash\ * ]]; then
    echo "Companion app is ad-hoc signed; run make setup-companion-signing for persistent Full Disk Access." >&2
    return
  fi

  marker_path="$(companion_tcc_marker_path)"
  {
    IFS= read -r previous_marker_version || true
    previous_requirement="$(cat || true)"
  } < <(read_companion_tcc_marker "${marker_path}")

  if [[ "${previous_requirement}" == "${requirement}" && "${previous_marker_version}" == "${marker_version}" ]]; then
    return
  fi

  if [[ -z "${previous_requirement}" ]]; then
    reset_companion_full_disk_access_entries
    echo "Reset stale Full Disk Access entries for ${COMPANION_BUNDLE_ID}."
    echo "Grant ${app_path} once; normal reloads will keep that grant."
  elif [[ "${previous_requirement}" != "${requirement}" ]]; then
    reset_companion_full_disk_access_entries
    echo "Companion signing requirement changed; reset stale Full Disk Access entries."
    echo "Grant ${app_path} once; normal reloads will keep that grant."
  else
    reset_companion_full_disk_access_entries
    echo "Companion Full Disk Access marker upgraded; reset stale privacy entries."
    echo "Grant ${app_path} once; normal reloads will keep that grant."
  fi

  write_companion_tcc_marker "${marker_path}" "${marker_version}" "${requirement}"
}

reset_companion_full_disk_access_for_app() {
  local app_path="$1"
  local marker_path
  local requirement
  local marker_version="4"

  requirement="$(companion_designated_requirement "${app_path}")"
  if [[ -z "${requirement}" ]]; then
    echo "Unable to read companion code-signing requirement; refusing to reset Full Disk Access." >&2
    exit 1
  fi

  reset_companion_full_disk_access_entries
  marker_path="$(companion_tcc_marker_path)"
  write_companion_tcc_marker "${marker_path}" "${marker_version}" "${requirement}"
  echo "Reset Full Disk Access entries for ${COMPANION_BUNDLE_ID}."
  echo "Grant the stable app at ${app_path}; normal reloads will not reset it."
}

reset_companion_full_disk_access_entries() {
  if command -v tccutil >/dev/null 2>&1; then
    tccutil reset SystemPolicyAllFiles "${COMPANION_BUNDLE_ID}" >/dev/null 2>&1 || true
  fi
}

companion_app_bundle_id() {
  local app_path="$1"
  local plist="${app_path}/Contents/Info.plist"

  [[ -f "${plist}" ]] || return 1
  /usr/bin/plutil -extract CFBundleIdentifier raw -o - "${plist}" 2>/dev/null
}

is_companion_app_bundle() {
  local app_path="$1"
  local bundle_id

  bundle_id="$(companion_app_bundle_id "${app_path}" || true)"
  [[ "${bundle_id}" == "${COMPANION_BUNDLE_ID}" ]]
}

unregister_stale_companion_apps() {
  local keep_app="${1:-}"

  [[ -x "${LSREGISTER}" ]] || return 0

  {
    if command -v mdfind >/dev/null 2>&1; then
      mdfind "kMDItemCFBundleIdentifier == '${COMPANION_BUNDLE_ID}'" 2>/dev/null || true
    fi
    find "${HOME}/Library/Developer/Xcode/DerivedData" \
      -name "Maraithon.app" \
      -type d \
      -print 2>/dev/null || true
  } | sort -u | while IFS= read -r app_path; do
    [[ -n "${app_path}" ]] || continue
    if [[ -n "${keep_app}" && "${app_path%/}" == "${keep_app%/}" ]]; then
      continue
    fi
    is_companion_app_bundle "${app_path}" || continue
    "${LSREGISTER}" -u "${app_path}" >/dev/null 2>&1 || true
  done
}

remove_derived_companion_apps() {
  local keep_app="${1:-}"
  local derived_data="${HOME}/Library/Developer/Xcode/DerivedData"

  [[ -d "${derived_data}" ]] || return 0

  find "${derived_data}" \
    -path "*/Build/Products/*/Maraithon.app" \
    -type d \
    -prune \
    -print 2>/dev/null |
    sort -u |
    while IFS= read -r app_path; do
      [[ -n "${app_path}" ]] || continue
      if [[ -n "${keep_app}" && "${app_path%/}" == "${keep_app%/}" ]]; then
        continue
      fi
      is_companion_app_bundle "${app_path}" || continue
      if [[ -x "${LSREGISTER}" ]]; then
        "${LSREGISTER}" -u "${app_path}" >/dev/null 2>&1 || true
      fi
      rm -rf "${app_path}"
    done
}

ios_destination() {
  if [[ -n "${IOS_DESTINATION:-}" ]]; then
    echo "${IOS_DESTINATION}"
    return
  fi

  require_command xcrun

  local simulator_regex="${MARAITHON_IOS_SIMULATOR_REGEX:-iPhone 17|iPhone 16|iPhone 15}"
  local simulator_line
  simulator_line="$(
    xcrun simctl list devices available |
      awk -v regex="${simulator_regex}" '
        /^-- iOS / { in_ios = 1; next }
        /^-- / { in_ios = 0 }
        in_ios && $0 ~ regex && $0 ~ /\([0-9A-Fa-f-]{36}\)/ {
          print
          exit
        }
      '
  )"

  local udid
  udid="$(printf "%s" "${simulator_line}" | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)).*/\1/p')"

  if [[ -z "${udid}" ]]; then
    echo "Unable to find an available iOS simulator. Set IOS_DESTINATION='platform=iOS Simulator,id=<UDID>'." >&2
    exit 1
  fi

  echo "platform=iOS Simulator,id=${udid}"
}
