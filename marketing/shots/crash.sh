#!/usr/bin/env bash
UDID=${UDID:-B63090D4-6D6F-467D-B504-672EA3E95500}
ssh "${MAC:-mac}" "xcrun simctl spawn $UDID log show --last 5m --predicate 'process == \"CrucibleShots\" AND (eventMessage CONTAINS \"uncaught exception\" OR eventMessage CONTAINS \"Fatal error\" OR eventMessage CONTAINS \"Assertion\")' --style default 2>/dev/null | grep -E 'uncaught exception|Fatal error|Assertion' | tail -3 | cut -c1-1500"
