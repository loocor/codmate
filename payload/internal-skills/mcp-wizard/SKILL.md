---
name: mcp-wizard
description: Generate MCP server drafts from requirements.
metadata:
  short-description: Generate MCP server drafts in JSON.
---

# MCP Wizard

## Overview

Generate a CodMate MCP server draft based on user intent. Output only JSON that matches the schema.

## Instructions

1. Determine server kind (stdio, sse, streamable_http).
2. Provide command/args/env for stdio, or url/headers for network kinds.
3. If unclear, return mode "question" with follow-up questions.

## Output

Return only JSON.
