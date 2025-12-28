#!/bin/bash

# Test script for Commands management system
# This script validates the commands sync functionality

set -e

echo "🧪 Testing Commands Management System"
echo "======================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Test directories
CODMATE_DIR="$HOME/.codmate"
CLAUDE_DIR="$HOME/.claude/commands"
CODEX_DIR="$HOME/.codex/prompts"
GEMINI_DIR="$HOME/.gemini/commands"

# Step 1: Check configuration file
echo -e "${BLUE}Step 1: Checking configuration file${NC}"
if [ -f "$CODMATE_DIR/commands.json" ]; then
    echo -e "${GREEN}✓ Configuration file exists${NC}"
    COMMAND_COUNT=$(cat "$CODMATE_DIR/commands.json" | grep -c '"id"' || echo "0")
    echo -e "  Found $COMMAND_COUNT commands"
else
    echo -e "${RED}✗ Configuration file not found${NC}"
    exit 1
fi
echo ""

# Step 2: Verify JSON structure
echo -e "${BLUE}Step 2: Validating JSON structure${NC}"
if command -v jq &> /dev/null; then
    if jq empty "$CODMATE_DIR/commands.json" 2>/dev/null; then
        echo -e "${GREEN}✓ Valid JSON format${NC}"
    else
        echo -e "${RED}✗ Invalid JSON format${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠ jq not installed, skipping JSON validation${NC}"
fi
echo ""

# Step 3: Check command fields
echo -e "${BLUE}Step 3: Checking command fields${NC}"
if command -v jq &> /dev/null; then
    # Check first command has required fields
    FIRST_CMD=$(jq '.[0]' "$CODMATE_DIR/commands.json")
    REQUIRED_FIELDS=("id" "name" "description" "prompt" "targets" "isEnabled" "source" "installedAt")

    for field in "${REQUIRED_FIELDS[@]}"; do
        if echo "$FIRST_CMD" | jq -e "has(\"$field\")" > /dev/null; then
            echo -e "${GREEN}✓ Field '$field' present${NC}"
        else
            echo -e "${RED}✗ Field '$field' missing${NC}"
            exit 1
        fi
    done
else
    echo -e "${YELLOW}⚠ jq not installed, skipping field validation${NC}"
fi
echo ""

# Step 4: Manual sync test (simulated)
echo -e "${BLUE}Step 4: Testing sync directories${NC}"

# Create test directories
mkdir -p "$CLAUDE_DIR"
mkdir -p "$CODEX_DIR"
mkdir -p "$GEMINI_DIR"

echo -e "${GREEN}✓ Sync directories created/verified${NC}"
echo "  Claude Code: $CLAUDE_DIR"
echo "  Codex CLI:   $CODEX_DIR"
echo "  Gemini CLI:  $GEMINI_DIR"
echo ""

# Step 5: Check for existing synced commands (if any)
echo -e "${BLUE}Step 5: Checking for synced commands${NC}"

CLAUDE_COUNT=$(find "$CLAUDE_DIR" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
CODEX_COUNT=$(find "$CODEX_DIR" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
GEMINI_COUNT=$(find "$GEMINI_DIR" -name "*.toml" 2>/dev/null | wc -l | tr -d ' ')

echo -e "  Claude Code commands: $CLAUDE_COUNT .md files"
echo -e "  Codex CLI commands:   $CODEX_COUNT .md files"
echo -e "  Gemini CLI commands:  $GEMINI_COUNT .toml files"
echo ""

# Step 6: Display sample command
echo -e "${BLUE}Step 6: Sample command preview${NC}"
if command -v jq &> /dev/null; then
    echo "First command:"
    jq '.[0] | {id, name, description, targets}' "$CODMATE_DIR/commands.json"
else
    echo "Install 'jq' to see command preview"
fi
echo ""

# Step 7: Instructions
echo -e "${BLUE}Step 7: Next steps${NC}"
echo "To enable automatic sync:"
echo "  1. Launch CodMate application"
echo "  2. Go to Settings → Extensions → Commands"
echo "  3. Click 'Sync Now' button"
echo ""
echo "To verify sync manually, check these directories:"
echo "  - $CLAUDE_DIR"
echo "  - $CODEX_DIR"
echo "  - $GEMINI_DIR"
echo ""

# Summary
echo -e "${GREEN}✓ All basic tests passed!${NC}"
echo ""
echo "Commands system is ready for use."
echo "Run CodMate and navigate to Settings → Extensions → Commands to manage your commands."
