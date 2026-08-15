#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="${PROJECT_DIR}/dist/VoixLocale.app"
CONTENTS="${APP_DIR}/Contents"

cd "${PROJECT_DIR}"
export CLANG_MODULE_CACHE_PATH="${PROJECT_DIR}/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="${PROJECT_DIR}/.build/ModuleCache"
swift build --disable-sandbox -c release
rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources/backend"
cp ".build/release/VoixLocale" "${CONTENTS}/MacOS/VoixLocale"
cp backend/app.py backend/requirements.txt backend/run_backend.sh \
   backend/system-requirements.txt "${CONTENTS}/Resources/backend/"
cp scripts/check_requirements.sh "${CONTENTS}/Resources/backend/"
cp assets/AppIcon.icns assets/Assets.car "${CONTENTS}/Resources/"
chmod +x "${CONTENTS}/Resources/backend/run_backend.sh" \
         "${CONTENTS}/Resources/backend/check_requirements.sh"
cp scripts/Info.plist "${CONTENTS}/Info.plist"
IDENTITY="${CODESIGN_IDENTITY:--}"
# Le serveur de timestamp Apple n'est utile que pour la notarisation ; inutile en ad-hoc.
if [[ "${IDENTITY}" == "-" ]]; then
  TIMESTAMP_FLAG="--timestamp=none"
else
  TIMESTAMP_FLAG="--timestamp"
fi
# --options runtime + l'entitlement micro sont indissociables : avec le Hardened Runtime
# et sans com.apple.security.device.audio-input, le processus est tué à l'accès micro.
codesign --force --options runtime "${TIMESTAMP_FLAG}" \
  --entitlements scripts/VoixLocale.entitlements \
  --sign "${IDENTITY}" "${APP_DIR}"
echo "Application créée : ${APP_DIR}"
