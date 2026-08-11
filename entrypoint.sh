#!/bin/sh
set -e

SERVER_VERSION=$(static-web-server --version 2>&1 | grep '^Version' | awk '{print $2}')

echo ""
echo "  Spade — DNS Security Inspector"
echo "  https://github.com/slmingol/spade--dns-inspector"
echo "  static-web-server v${SERVER_VERSION}"
echo "  Listening on :${SERVER_PORT:-80}"
echo ""

exec static-web-server "$@"
