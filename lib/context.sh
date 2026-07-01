#!/usr/bin/env bash
# Cerberus Project Context — shared library for coach/reviewer crons
# 
# Context files are JSON with two sections:
#   auto    — fields the script updates from on-chain data (status, IDs, timestamps)
#   llm     — fields the LLM updates (maturity, checklist, reasoning, open items)
#
# Functions:
#   context_load <handle>          — writes JSON to stdout (or {} if missing)
#   context_save <handle>          — reads JSON from stdin, merges with existing, writes
#   context_update <handle> <json> — partial update: merges <json> into context
#   context_upsert_from_pr         — creates/updates context from a project review node
#   context_index_refresh          — rebuild index.json from all context files
#   context_list                   — table of all projects
#   learned_load_all               — markdown block of all self-learned skills
#   learned_index_refresh          — rebuild learned/index.json from .md files
#   learned_list                   — table of self-learned skills

CONTEXT_DIR="${CONTEXT_DIR:-$HOME/.cerberus/projects}"
INDEX_FILE="$CONTEXT_DIR/index.json"
LEARNED_DIR="${LEARNED_DIR:-$HOME/.cerberus/learned}"
LEARNED_INDEX="$LEARNED_DIR/index.json"

# ═══════════════════════════════════════════════════════════════════════════════
# Project Context — per-project ledger
# ═══════════════════════════════════════════════════════════════════════════════

context_load() {
  local handle="$1"
  local file="$CONTEXT_DIR/$handle.json"
  if [ -f "$file" ]; then
    cat "$file"
  else
    echo '{}'
  fi
}

context_save() {
  local handle="$1"
  local file="$CONTEXT_DIR/$handle.json"
  mkdir -p "$CONTEXT_DIR"
  cat > "$file"
  context_index_refresh
}

context_update() {
  local handle="$1"
  local merge="$2"
  local existing
  existing=$(context_load "$handle")
  echo "$existing" | jq --argjson merge "$merge" '. * $merge' | context_save "$handle"
}

# Create or update context from a project review summary node (JSON on stdin)
context_upsert_from_pr() {
  local node
  node=$(cat)
  local handle
  handle=$(echo "$node" | jq -r '.projectReviewId // empty')
  [ -z "$handle" ] && return 0
  handle="pr-$handle"
  
  local existing
  existing=$(context_load "$handle")
  
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  echo "$existing" | jq \
    --argjson node "$node" \
    --arg now "$now" \
    '{
      auto: {
        project_review_id: ($node.projectReviewId // null),
        owner: ($node.owner // ""),
        idea: ($node.idea // ""),
        github_url: ($node.githubUrl // ""),
        status: ($node.status // ""),
        guidance: ($node.latestGuidanceOutcome // null),
        linked_program_id: ($node.linkedProgramId // null),
        comment_count: ($node.commentCount // 0),
        last_activity: $now
      }
    } * .' | context_save "$handle"
}

# Auto-create/update context from application data
context_upsert_from_app() {
  local handle="$1"
  local app_json
  app_json=$(cat)
  local existing
  existing=$(context_load "$handle")
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  echo "$existing" | jq \
    --argjson app "$app_json" \
    --arg now "$now" \
    '{
      auto: {
        program_id: ($app.programId // ($app.id // "")),
        owner: ($app.owner // ""),
        github_url: ($app.githubUrl // ""),
        stage_gate: { published: ($app.status // "unknown") },
        last_activity: $now
      }
    } * .' | context_save "$handle"
}

context_index_refresh() {
  local merged='{}'
  for f in "$CONTEXT_DIR"/*.json; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "index.json" ] && continue
    local handle
    handle=$(basename "$f" .json)
    local stage
    stage=$(jq -r '.auto.stage_gate.published // "unknown"' "$f")
    local last
    last=$(jq -r '.auto.last_activity // ""' "$f")
    local owner
    owner=$(jq -r '.auto.owner // ""' "$f")
    local entry
    entry=$(jq -nc \
      --arg handle "$handle" \
      --arg stage "$stage" \
      --arg last "$last" \
      --arg owner "$owner" \
      '{($handle): {handle: $handle, stage: $stage, last: $last, owner: $owner}}')
    merged=$(echo "$merged" | jq --argjson e "$entry" '. * $e')
  done
  
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -nc --argjson projects "$merged" --arg now "$now" \
    '{version: 1, updated_at: $now, projects: $projects}' > "$INDEX_FILE"
}

context_list() {
  if [ -f "$INDEX_FILE" ]; then
    jq -r '.projects | to_entries[] | "\(.value.stage)\t\(.key)\t\(.value.last // "never")\t\(.value.owner // "?")"' "$INDEX_FILE" | sort -t$'\t' -k2
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Self-Learning Skills — cross-project pattern accumulation
# ═══════════════════════════════════════════════════════════════════════════════

# Rebuild learned/index.json from all .md files
learned_index_refresh() {
  mkdir -p "$LEARNED_DIR"
  local merged='{}'
  for f in "$LEARNED_DIR"/*.md; do
    [ -f "$f" ] || continue
    local name
    name=$(basename "$f" .md)
    # Extract description from YAML frontmatter (folded scalar after description: >)
    local desc
    desc=$(sed -n '/^description: >/,/^---/p' "$f" | head -8 | tr '\n' ' ' | sed 's/.*> //; s/---//; s/^ *//; s/ *$//')
    local learned_at
    learned_at=$(stat -c '%Y' "$f" 2>/dev/null || echo "0")
    local entry
    entry=$(jq -nc --arg n "$name" --arg d "$desc" --argjson t "$learned_at" \
      '{($n): {name: $n, description: $d, learned_at: $t}}')
    merged=$(echo "$merged" | jq --argjson e "$entry" '. * $e')
  done
  jq -nc --argjson skills "$merged" --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{version: 1, updated_at: $now, skills: $skills}' > "$LEARNED_INDEX"
}

# List all learned skills (stdout table)
learned_list() {
  if [ -f "$LEARNED_INDEX" ]; then
    jq -r '.skills | to_entries[] | "\(.value.learned_at | strftime("%Y-%m-%d"))\t\(.key)\t\(.value.description[0:80])..."' "$LEARNED_INDEX" | sort -t$'\t' -k2
  fi
}

# Load ALL learned skills as a markdown block for LLM injection
# Usage: learned_load_all >> report
learned_load_all() {
  mkdir -p "$LEARNED_DIR"
  learned_index_refresh 2>/dev/null
  
  local count
  count=$(jq -r '.skills | length // 0' "$LEARNED_INDEX" 2>/dev/null || echo 0)
  
  [ "$count" -eq 0 ] && return 0
  
  echo "## 🔁 Self-Learned Skills (accumulated patterns)"
  echo ""
  echo "The following skills were learned from previous review sessions."
  echo "They capture patterns, gotchas, and guidance templates discovered"
  echo "through actual project evaluations. Load them into your reasoning."
  echo ""
  
  for f in "$LEARNED_DIR"/*.md; do
    [ -f "$f" ] || continue
    local name
    name=$(basename "$f" .md)
    [ "$name" = "index" ] && continue
    echo "---"
    echo "### Learned skill: $name"
    echo ""
    cat "$f"
    echo ""
  done
  
  echo "---"
  echo ""
}

# Export for use by crons
export -f context_load context_save context_update context_upsert_from_pr context_upsert_from_app context_index_refresh context_list
export -f learned_index_refresh learned_list learned_load_all
export CONTEXT_DIR INDEX_FILE LEARNED_DIR LEARNED_INDEX
