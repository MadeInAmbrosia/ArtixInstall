#!/bin/bash
set -euo pipefail

MODE="auto"

for arg in "$@"; do
    case "$arg" in
    -m | --manual)
        MODE="manual"
        ;;
    -h | --help)
        echo "Usage:"
        echo "  ./install        # auto install"
        echo "  ./install -m     # manual install"
        exit 0
        ;;
    esac
done

if [[ "$MODE" == "manual" ]]; then
    if [[ ! -f "./scripts/install_manual.sh" ]]; then
        echo "[ERROR] install_manual.sh not found"
        exit 1
    fi

    exec bash ./scripts/install_manual.sh
else
    if [[ ! -f "./scripts/install_auto.sh" ]]; then
        echo "[ERROR] install_auto.sh not found"
        exit 1
    fi

    exec bash ./scripts/install_auto.sh
fi
