#!/bin/bash
set -euo pipefail

MODE="auto"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -eq 0 ]]; then
    MODE="auto"
fi

for arg in "$@"; do
    case "$arg" in
    -a | --auto)
        MODE="auto"
        ;;
    -m | --manual)
        MODE="manual"
        ;;
    *)
        echo "[ERROR] Unknown option: $arg"
        echo "Usage: ./install [-a|--auto] [-m|--manual]"
        exit 1
        ;;
    esac
done

if [[ "$MODE" == "manual" ]]; then
    [[ -f "$SCRIPT_DIR/scripts/install_manual.sh" ]] || {
        echo "[ERROR] install_manual.sh not found"
        exit 1
    }
    exec bash "$SCRIPT_DIR/scripts/install_manual.sh"

else
    [[ -f "$SCRIPT_DIR/scripts/install_auto.sh" ]] || {
        echo "[ERROR] install_auto.sh not found"
        exit 1
    }
    exec bash "$SCRIPT_DIR/scripts/install_auto.sh"
fi
