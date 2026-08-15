#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SUPPORT_DIR="${HOME}/Library/Application Support/VoixLocale"
VENV_DIR="${SUPPORT_DIR}/venv"
LOG_DIR="${HOME}/Library/Logs"
mkdir -p "${SUPPORT_DIR}" "${LOG_DIR}"
export UV_CACHE_DIR="${SUPPORT_DIR}/cache/uv"
export UV_PYTHON_INSTALL_DIR="${SUPPORT_DIR}/runtime/python"
export HF_HOME="${SUPPORT_DIR}/models"

# Échouer tôt et lisiblement si ffmpeg/ffprobe manquent, plutôt qu'au moment de
# générer un MP3 ou d'enrôler une voix.
if [[ -x "${SCRIPT_DIR}/check_requirements.sh" ]]; then
  "${SCRIPT_DIR}/check_requirements.sh" || exit 1
fi

if [[ -x "/opt/homebrew/bin/uv" ]]; then
  UV_BIN="/opt/homebrew/bin/uv"
elif [[ -x "${HOME}/.local/bin/uv" ]]; then
  UV_BIN="${HOME}/.local/bin/uv"
elif command -v uv >/dev/null 2>&1; then
  UV_BIN="$(command -v uv)"
else
  echo "uv est requis. Installez-le avec: brew install uv" >&2
  exit 1
fi

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  "${UV_BIN}" venv --python 3.12 "${VENV_DIR}"
fi

REQ_HASH="$(shasum -a 256 "${SCRIPT_DIR}/requirements.txt" | cut -d ' ' -f 1)"
MARKER="${VENV_DIR}/.voixlocale-requirements"
if [[ ! -f "${MARKER}" ]] || [[ "$(<"${MARKER}")" != "${REQ_HASH}" ]]; then
  "${UV_BIN}" pip install --python "${VENV_DIR}/bin/python" -r "${SCRIPT_DIR}/requirements.txt"
  print -r -- "${REQ_HASH}" > "${MARKER}"
fi

export VOIXLOCALE_DATA_DIR="${SUPPORT_DIR}"
exec "${VENV_DIR}/bin/python" -m uvicorn app:app \
  --app-dir "${SCRIPT_DIR}" --host 127.0.0.1 --port 8765 --log-level info
