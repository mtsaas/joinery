#!/bin/sh
# Keeps the core free of the app around it: the data model (Joinery/Document) and the session protocol
# (Joinery/Collaboration/Protocol) are plain state and state machines, with no UI, no networking, no main actor, and
# nothing from the rest of the app. Everything else may use them; they use nothing else. Run from the repository root;
# prints what breaks the rule and fails, or prints nothing.
cd "$(dirname "$0")/.." || exit 1
core="Joinery/Document Joinery/Collaboration/Protocol"
status=0

# Only these frameworks.
bad=$(grep -n '^import ' $(find $core -name '*.swift') | grep -vE 'import (Foundation|CoreGraphics|UniformTypeIdentifiers)$')
[ -n "$bad" ] && { echo "Frameworks the core mustn't use:"; echo "$bad"; status=1; }

# Nothing from the app, the network or the screen, by name.
names='@MainActor|\bNS[A-Z][A-Za-z]*(Pasteboard|View|Window|Color|Image|Event|Application)\b|URLSession|\bNW[A-Z]|SocketPeer|SessionHost|SessionClient|\bSession\b|OpenModel|\bLibrary\b|CanvasController|\bTheme\b|ModelTools|MCPServer|Color\('
bad=$(grep -nE "$names" $(find $core -name '*.swift') | grep -vE '^\S+:[0-9]+:\s*///')
[ -n "$bad" ] && { echo "App, network or UI names in the core:"; echo "$bad"; status=1; }
exit $status
