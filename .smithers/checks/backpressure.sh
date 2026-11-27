#!/bin/sh
# Run Uphill scoring and regenerate the Lighthouse-style Backpressure Audit Report.
set -eu

node tools/audit_report.mjs --run --publish-docs docs/public/audit/index.html "$@"
