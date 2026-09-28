#!/usr/bin/env bash
# Reproduce the CI hardening flow locally (tt-gds-action@ttsky26d):
#   tt-support-tools checked out at ./tt (not committed; .gitignore has it)
#   ~/venv-harden (python3.11): pip install -r tt/requirements.txt librelane==3.0.14
#   LibreLane runs dockerized (docker must work without sudo).
set -e
cd "$(dirname "$0")/.."
export PATH="$HOME/venv-harden/bin:$PATH"

./tt/tt_tool.py --create-user-config
./tt/tt_tool.py --harden
