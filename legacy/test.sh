#!/bin/bash
# Quick test script for local development

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Testing rdock locally..."
echo ""

# Check Python
if [ ! -f "$SCRIPT_DIR/.conda/bin/python" ]; then
    echo "❌ Conda environment not found. Run install.sh first or create manually:"
    echo "   conda create -p .conda python=3.11"
    echo "   .conda/bin/pip install -r requirements.txt"
    exit 1
fi

echo "✓ Python environment found"

# Check dependencies
if ! "$SCRIPT_DIR/.conda/bin/python" -c "import aiohttp" 2>/dev/null; then
    echo "❌ Dependencies missing. Installing..."
    "$SCRIPT_DIR/.conda/bin/pip" install -r requirements.txt
fi

echo "✓ Dependencies installed"
echo ""

# Check tmux
if ! command -v tmux &> /dev/null; then
    echo "⚠ tmux not found - terminal sessions won't persist"
else
    echo "✓ tmux available"
fi

echo ""
echo "Starting server on http://localhost:8890 ..."
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Run server
cd "$SCRIPT_DIR"
.conda/bin/python server.py
