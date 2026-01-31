---
name: hooks-wizard
description: Generate CodMate hook drafts from requirements.
metadata:
  short-description: Generate hook configuration drafts in JSON.
---

# Hooks Wizard

## Overview

Generate a CodMate Hook draft based on the user's requirement and provided event/variable catalogs. Output only JSON that matches the schema.

## Instructions

1. Read the user's request and any conversation context.
2. Choose the most appropriate event and matcher from the catalog.
3. Produce a Hook draft with one or more commands.
4. If the requirement is unclear, return mode "question" with follow-up questions.

## Output

Return only JSON.
