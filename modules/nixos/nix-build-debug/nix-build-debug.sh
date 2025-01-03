#! /usr/bin/env bash

search="$1"
pid="$(pgrep -f "$search" | head -n1)"
shell=$(
  sudo nsenter --mount --target $pid /bin/sh -c '
    while read line; do
      case $line in
        *shell=* )
          echo $line
            ;;
      esac
    done < /build/env-vars
  ' | cut -d \" -f 2
)
sudo nsenter --mount --target $pid "$shell" -c "source /build/env-vars && exec $shell"
