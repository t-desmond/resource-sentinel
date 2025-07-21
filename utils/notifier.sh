#!/bin/bash
pid="$1"
proc="$2"
cpu="$3"
mem="$4"

HOST_OS="$(uname -s)"

notify_user_cli() {
  echo "High usage detected: $proc (PID $pid) CPU: $cpu% MEM: $mem%"
  echo "Options: [k]ill, [i]gnore, [r]emind me later"
  read -rp "Choose an action: " choice
  case "$choice" in
    k|K) echo "kill" ;;
    i|I) echo "ignore" ;;
    r|R) echo "remind" ;;
    *) echo "ignore" ;;
  esac
}

notify_user() {
  if [[ "$HOST_OS" == "Darwin" ]]; then
    # AppleScript dialog
    response=$(osascript -e "button returned of (display dialog \
      "Process: $proc (PID $pid)\nCPU: $cpu% MEM: $mem%\nChoose action:" buttons {"Kill", "Ignore", "Remind Me Later"} default button "Remind Me Later")")
    case "$response" in
      Kill) echo "kill" ;;
      Ignore) echo "ignore" ;;
      Remind*) echo "remind" ;;
      *) echo "ignore" ;;
    esac
  elif command -v zenity &>/dev/null; then
    # Use 2>/dev/null to suppress Gtk warning messages
    response=$(zenity --question --title="High Resource Usage" \
      --text="Process: $proc (PID $pid)\nCPU: $cpu% MEM: $mem%\nChoose action:" \
      --ok-label="Kill" --cancel-label="Ignore" --extra-button="Remind Me Later" 2>/dev/null)
    exit_code=$?

    if [[ "$response" == "Remind Me Later" ]]; then
      echo "remind"
    elif [[ $exit_code -eq 0 ]]; then
      echo "kill"
    else # exit_code is 1 or something else (dialog closed)
      echo "ignore"
    fi
  else
    notify_user_cli
  fi
}

notify_user
