#!/bin/sh
# Runs ReaderShell.app with its output kept in a log next to it, for the
# first runs on a device (libinkview/docs/building.md section 6.2). Copy it
# to applications/ beside ReaderShell.app and start this one instead.
#
# GLIBC_TUNABLES: firmware 6.11.1480 refuses to dlopen libinkview.so, whose
# stack is marked executable, without it (KOReader's fix; harmless elsewhere).
export GLIBC_TUNABLES=glibc.rtld.execstack=2
APP=/mnt/ext1/applications/ReaderShell.app
LOG=/mnt/ext1/applications/ReaderShell.log
echo "=== $(date) starting $APP" >> "$LOG"
"$APP" "$@" >> "$LOG" 2>&1
echo "=== exit code: $? ===" >> "$LOG"
