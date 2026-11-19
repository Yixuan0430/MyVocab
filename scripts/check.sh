#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/.."

NO_COMMENTS="${HOME}/.gemini/config/agents/software-engineer/scripts/check_no_comments.py"
CODE_HEALTH="${HOME}/.gemini/config/agents/software-engineer/scripts/check_code_health.py"

STATUS=0

CODE_FILES=()
while IFS= read -r -d '' f; do
    CODE_FILES+=("$f")
done < <(find Sources Tests scripts -type f \( -name '*.swift' -o -name '*.py' -o -name '*.sh' \) -print0)

for f in bundle.sh release.sh release-ios.sh; do
    if [ -f "$f" ]; then
        CODE_FILES+=("$f")
    fi
done

if [ -f "$NO_COMMENTS" ]; then
    python3 "$NO_COMMENTS" "${CODE_FILES[@]}" || STATUS=1
fi

if [ -f "$CODE_HEALTH" ]; then
    python3 "$CODE_HEALTH" --repo-root . "${CODE_FILES[@]}" || STATUS=1
fi

swiftlint lint --quiet --strict Sources Tests scripts/make-icon.swift || STATUS=1
ruff check --no-cache scripts/*.py || STATUS=1
shellcheck -S warning bundle.sh release.sh release-ios.sh scripts/check.sh || STATUS=1

swift test || STATUS=1
BIN="$(swift build --show-bin-path)/MyVocab"
python3 scripts/check-mcp.py "$BIN" || STATUS=1

exit "$STATUS"
