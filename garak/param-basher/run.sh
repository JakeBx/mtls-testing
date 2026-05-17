#!/bin/bash

# Smoke test runner for HyperparamBasher
#
# Suffix convention — what each test verifies:
#   _RUN   probe loads and runs (API auth failures are acceptable without a live key)
#   _WARN  same as _RUN, but additionally confirms a specific warning appears in garak.log
#   _RAISE garak internally raises PluginConfigurationError; exits 0 (graceful degradation)
#          and logs an error message — verified by grep, not exit code
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Fall back to OPENROUTER_API_KEY if the OpenAI-compat key is unset
: "${OPENAICOMPATIBLE_API_KEY:=${OPENROUTER_API_KEY:-}}"
export OPENAICOMPATIBLE_API_KEY

GARAK_LOG="$HOME/.local/share/garak/garak.log"

pattern='^[0-9]+.*_(RUN|WARN|RAISE)\.json$'
failures=0

ok()   { printf "\033[1;32mOK\033[0m: %s\n" "$*"; }
fail() { printf "\033[1;31mFAIL\033[0m: %s\n" "$*"; (( failures++ )) || true; }

for config_file in *.json; do
    [[ "$config_file" =~ $pattern ]] || continue

    echo ""
    echo "=========================================="
    printf "\033[1;4m%s\033[0m\n" "$config_file"
    echo "=========================================="
    echo ""

    # Record log position before run so we only grep new entries
    log_before=$(wc -l < "$GARAK_LOG" 2>/dev/null || echo 0)

    # Capture combined output; ignore exit code — we grep for expected content
    out=$(conda run -n garak python -m garak --config "$config_file" 2>&1) || true
    printf '%s\n' "$out"

    if [[ "$config_file" =~ _RAISE\.json$ ]]; then
        # Probe init should raise PluginConfigurationError — garak exits 0 but logs the error
        if printf '%s\n' "$out" | grep -qE "failed to load probe|not supported by generator|defines a custom _generator_precall_hook"; then
            ok "$config_file — PluginConfigurationError logged as expected"
        else
            fail "$config_file — expected error message not found in output"
        fi

    elif [[ "$config_file" =~ _WARN\.json$ ]]; then
        # Probe must load; non-compat generator warning must appear in garak.log
        if printf '%s\n' "$out" | grep -q "hyperparams.HyperparamBasher"; then
            ok "$config_file — probe loaded correctly"
        else
            fail "$config_file — HyperparamBasher not found in output"
        fi
        new_log=$(tail -n +"$((log_before + 1))" "$GARAK_LOG" 2>/dev/null || true)
        if printf '%s\n' "$new_log" | grep -q "may not apply inference param changes"; then
            ok "$config_file — non-compatible generator WARNING found in garak.log"
        else
            fail "$config_file — non-compatible generator WARNING missing from garak.log"
        fi

    else
        # _RUN: probe must load; auth failures mid-run are acceptable without a live key
        if printf '%s\n' "$out" | grep -q "hyperparams.HyperparamBasher"; then
            ok "$config_file — probe loaded correctly"
        else
            fail "$config_file — HyperparamBasher not found in output"
        fi
    fi

    echo ""
done

echo ""
if (( failures > 0 )); then
    printf "\033[1;31m%d test(s) did not behave as expected.\033[0m\n" "$failures"
    exit 1
fi
echo "All smoke tests completed successfully."
