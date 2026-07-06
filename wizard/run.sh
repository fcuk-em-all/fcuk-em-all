#!/usr/bin/env bash
# wizard/run.sh - LOCAL-DEV-ONLY launcher. The REAL run path is the container
# (compose/wizard.yml -> wizard:8088 on the fcuk-em-all network). This script is
# just a convenience for hacking on the app on the host; it binds loopback by
# default (override with WIZARD_HOST). The host process is NO LONGER how the
# wizard is served - host-gateway, the 0.0.0.0 host bind, and the firewall rule
# are all retired.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source .venv/bin/activate
exec uvicorn app:app --host "${WIZARD_HOST:-127.0.0.1}" --port "${WIZARD_PORT:-8088}"
