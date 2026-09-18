#!/usr/bin/env bash
# Run in a fresh checkout on macOS. AltStore must sign the result for the device.
set -euo pipefail

fail() { printf '%s\n' "$1" >&2; exit 1; }

export OPENVISION_META_MODE="${OPENVISION_META_MODE:-developer}"
export PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:-com.antoniorg00.openvision}"
export APP_LINK_URL_SCHEME="${APP_LINK_URL_SCHEME:-openvision}"

case "$OPENVISION_META_MODE" in
  developer)
    # Meta's SDK supports MetaAppID=0 with Developer Mode in the Meta AI app.
    export DEVELOPMENT_TEAM='' META_APP_ID='0' CLIENT_TOKEN=''
    ;;
  registered)
    for config_name in DEVELOPMENT_TEAM META_APP_ID CLIENT_TOKEN; do
      [[ -n "${!config_name:-}" ]] || fail "Missing configuration: $config_name"
    done
    [[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] || fail 'Invalid Apple Team ID.'
    [[ "$META_APP_ID" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid registered Meta App ID.'
    [[ "$CLIENT_TOKEN" =~ ^AR\|[0-9]+\|[A-Za-z0-9_-]+$ ]] || fail 'Use the complete Meta client token: AR|APP_ID|TOKEN.'
    [[ "$CLIENT_TOKEN" == "AR|${META_APP_ID}|"* ]] || fail 'Meta client token and App ID do not match.'
    ;;
  *) fail 'OPENVISION_META_MODE must be developer or registered.' ;;
esac
[[ "$PRODUCT_BUNDLE_IDENTIFIER" =~ ^[A-Za-z0-9]+(\.[A-Za-z0-9]+)+$ ]] || fail 'Invalid bundle identifier; Meta does not support dashes.'
[[ "$APP_LINK_URL_SCHEME" =~ ^[A-Za-z][A-Za-z0-9.-]*$ ]] || fail 'Invalid callback URL scheme.'

if [[ "${1:-}" == '--check-config' && "$#" == 1 ]]; then
  printf '%s\n' "Configuration format checked ($OPENVISION_META_MODE). Device testing is still required."
  exit 0
fi
[[ "$#" == 0 ]] || fail 'Usage: build-personal-ipa.sh [--check-config]'
[[ "$(uname -s)" == Darwin ]] || fail 'Building requires macOS with Xcode.'

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
[[ ! -e Config.xcconfig && ! -e OpenVision/Config/Config.swift ]] || fail 'Use a fresh checkout; existing configuration will not be overwritten.'
umask 077
cat > Config.xcconfig <<EOF
DEVELOPMENT_TEAM = ${DEVELOPMENT_TEAM}
PRODUCT_BUNDLE_IDENTIFIER = ${PRODUCT_BUNDLE_IDENTIFIER}
META_APP_ID = ${META_APP_ID}
CLIENT_TOKEN = ${CLIENT_TOKEN}
APP_LINK_URL_SCHEME = ${APP_LINK_URL_SCHEME}
EOF
cp OpenVision/Config/Config.swift.example OpenVision/Config/Config.swift
mkdir -p build
python3 - <<'PY'
import os
import plistlib
from pathlib import Path

info = plistlib.loads(Path('OpenVision/Resources/Info.plist').read_bytes())
if os.environ['OPENVISION_META_MODE'] == 'developer':
    info['MWDAT']['MetaAppID'] = '0'
    info['MWDAT'].pop('ClientToken', None)
    info['MWDAT'].pop('TeamID', None)
info.setdefault('NSLocalNetworkUsageDescription',
                'OpenVision connects to your Meta glasses over Wi-Fi to stream their camera.')
services = info.setdefault('NSBonjourServices', [])
if '_bonjour._tcp' not in services:
    services.append('_bonjour._tcp')
# This is a fresh CI checkout. Change only the app's input plist, so a global
# INFOPLIST_FILE override cannot leak app metadata into Swift package bundles.
Path('OpenVision/Resources/Info.plist').write_bytes(plistlib.dumps(info, sort_keys=False))
PY
xcodegen generate
xcodebuild \
  -project OpenVision.xcodeproj \
  -scheme OpenVision \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  build

app_path="$project_root/build/DerivedData/Build/Products/Release-iphoneos/OpenVision.app"
[[ -d "$app_path" ]] || fail 'Build did not produce OpenVision.app.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")" == "$PRODUCT_BUNDLE_IDENTIFIER" ]] || fail 'Built bundle identifier does not match.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MWDAT:MetaAppID' "$app_path/Info.plist")" == "$META_APP_ID" ]] || fail 'Built Meta App ID does not match.'
if [[ "$OPENVISION_META_MODE" == registered ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :MWDAT:TeamID' "$app_path/Info.plist")" == "$DEVELOPMENT_TEAM" ]] || fail 'Built Apple Team ID does not match.'
else
  if /usr/libexec/PlistBuddy -c 'Print :MWDAT:TeamID' "$app_path/Info.plist" >/dev/null 2>&1; then
    fail 'Developer build unexpectedly contains a registered Team ID.'
  fi
fi

# Preserve the requested memory entitlement for AltStore's re-signing step.
# This ad-hoc signature is not a device provisioning/signing certificate.
if [[ -d "$app_path/Frameworks" ]]; then
  while IFS= read -r -d '' bundled_code; do
    codesign --force --sign - "$bundled_code"
  done < <(find "$app_path/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
fi
codesign --force --sign - --entitlements OpenVision/OpenVision.entitlements "$app_path"
codesign --verify --deep --strict "$app_path"

package_dir="$(mktemp -d "$project_root/build/package.XXXXXX")"
mkdir -p "$package_dir/Payload"
ditto "$app_path" "$package_dir/Payload/OpenVision.app"
ditto -c -k --keepParent "$package_dir/Payload" "$project_root/build/OpenVision-unsigned.ipa"
(cd build && shasum -a 256 OpenVision-unsigned.ipa > OpenVision-unsigned.ipa.sha256)
cat > build/LEEME.txt <<EOF
OpenVision - compilacion personal ($OPENVISION_META_MODE)

Este archivo necesita la firma de AltStore Classic antes de instalarse.
Conecta el iPhone a Wi-Fi y activa LocalDevVPN.
Importa OpenVision-unsigned.ipa desde My Apps / Mis apps en AltStore Classic.

Si es una compilacion developer, activa Modo de desarrollador en Meta AI:
Ajustes > Informacion de la app > toca cinco veces el numero de version.
Con las gafas emparejadas, abre OpenVision y completa el registro con Meta AI.
Configura tu proveedor de IA en los ajustes de OpenVision.

Compilar e instalar no verifica la conexion con las gafas; falta probarla.
No hay claves de los proveedores de IA incluidas en esta app.
EOF
printf '%s\n' 'Created build/OpenVision-unsigned.ipa. Signing and device installation are still required.'
