#!/bin/zsh
# `swift run` produit un exécutable nu, sans bundle ni Info.plist : macOS tue alors le
# processus dès qu'il demande l'accès au microphone (NSMicrophoneUsageDescription absent).
# On construit donc toujours le bundle .app, puis on le lance.
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "${PROJECT_DIR}"
zsh scripts/build_app.sh
open "${PROJECT_DIR}/dist/VoixLocale.app"
echo "Logs : Console.app, ou tail -f ~/Library/Logs/voixlocale-backend.log"
