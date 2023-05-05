#!/bin/sh

condition=$(zpool status | grep -E 'DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|FAIL|DESTROYED|corrupt|cannot|unrecover')

if [ "${condition}" ]; then
  printf "\n==== ERROR ====\n"
  printf "One of the pools is in one of these statuses: DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|FAIL|DESTROYED|corrupt|cannot|unrecover!\n"
  printf "$condition"
  exit 1
fi
