#!/bin/zsh
# Vérifie les prérequis système déclarés dans backend/system-requirements.txt.
#   check_requirements.sh            → rapport, sort en 1 s'il manque quelque chose
#   check_requirements.sh --install  → installe les formules Homebrew manquantes
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
# Dans l'app packagée, ce script et system-requirements.txt vivent côte à côte
# dans Contents/Resources/backend ; en dépôt, le fichier est dans backend/.
if [[ -f "${PROJECT_DIR}/backend/system-requirements.txt" ]]; then
  REQ_FILE="${PROJECT_DIR}/backend/system-requirements.txt"
else
  REQ_FILE="${0:A:h}/system-requirements.txt"
fi

INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

# Homebrew n'exporte pas toujours son PATH aux processus lancés par launchd/Finder.
for dir in /opt/homebrew/bin /usr/local/bin; do
  [[ -d "${dir}" && ":${PATH}:" != *":${dir}:"* ]] && PATH="${dir}:${PATH}"
done
export PATH

typeset -a missing_formulae
missing_count=0

while IFS= read -r line; do
  line="${line%%#*}"
  [[ -z "${line// }" ]] && continue
  read -r binary formula description <<< "${line}"
  if command -v "${binary}" >/dev/null 2>&1; then
    printf '  ✓ %-9s %s\n' "${binary}" "$(command -v "${binary}")"
  else
    printf '  ✗ %-9s MANQUANT — %s\n' "${binary}" "${description}"
    missing_count=$((missing_count + 1))
    [[ " ${missing_formulae[*]} " == *" ${formula} "* ]] || missing_formulae+=("${formula}")
  fi
done < "${REQ_FILE}"

if (( missing_count == 0 )); then
  echo "Tous les prérequis système sont présents."
  exit 0
fi

if (( INSTALL )); then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew est requis pour l'installation automatique : https://brew.sh" >&2
    exit 1
  fi
  echo "Installation : brew install ${missing_formulae[*]}"
  brew install "${missing_formulae[@]}"
  exec "${0:A}"
fi

echo ""
echo "Installez les prérequis manquants avec :"
echo "  brew install ${missing_formulae[*]}"
echo "ou relancez ce script avec --install."
exit 1
