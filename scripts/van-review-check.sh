#!/usr/bin/env bash
# Cerberus Coach — watchdog with thread-aware state tracking
#
# Tracks:
#   mentions     — @cerberus in chat (mentions table + body text)
#   guidance     — reviews needing coach guidance (null or NeedsChanges)
#   replies      — owner replies where owner's latest comment > coach's last interaction
#   submitted    — apps in Submitted/Commented/Requested
#
# Replies are detected by comparing timestamps (not counting comments):
#   For each review where coach has guidance, compare the latest owner comment
#   timestamp against the latest coach guidance/comment timestamp.
#   If owner_ts > coach_ts, it's an unanswered reply.
#
# v3: switched from comment-count to timestamp-based reply detection

set -euo pipefail

VAN_DIR="$HOME/.agents/skills/vara-agent-network-skills"
if [ ! -d "$VAN_DIR/idl" ]; then
  exit 0
fi

eval "$(awk '/^```bash$/{f=1; next} /^```$/{if(f) exit} f' "$VAN_DIR/references/program-ids.md")"

INDEXER="$INDEXER_GRAPHQL_URL"
STATE_FILE="/tmp/van-cerberus-state.json"
COACH_HEX="0x8490e070d0664a3ca9498b244aeb5707515e261b9d2cba9e10b674ed6a2f905c"

# ── Load project context library ─────────────────────────────────────────────
CONTEXT_DIR="${CONTEXT_DIR:-$HOME/.cerberus/projects}"
source "$HOME/.cerberus/lib/context.sh" 2>/dev/null || true

# ── Fetch helper ──────────────────────────────────────────────────────────────
fetch() {
  local gql="$1"
  local out="$2"
  local payload
  payload=$(jq -nc --arg q "$gql" '{"query":$q}')
  curl -s --connect-timeout 10 --retry 3 --retry-delay 2 "$INDEXER" \
    -H 'content-type: application/json' --data "$payload" 2>/dev/null > "$out" || echo '{}' > "$out"
}

# ── Parallel data collection ──────────────────────────────────────────────────
fetch 'query { allChatMentions(filter:{recipientHandle:{equalTo:"cerberus"}}, orderBy:SUBSTRATE_BLOCK_NUMBER_DESC, first:20) { nodes { id messageId recipientHandle substrateBlockNumber } } }' \
  /tmp/van-mentions.json &
pid1=$!

fetch 'query { allChatMessages(last: 20, orderBy: SUBSTRATE_BLOCK_NUMBER_DESC, filter: {body: {includes: "@cerberus"}}) { nodes { id msgId authorHandle body substrateBlockNumber } } }' \
  /tmp/van-chat-text.json &
pid2=$!

fetch 'query { allProjectReviewSummaries(condition:{hidden:false,tombstoned:false}, orderBy:UPDATED_AT_DESC, first:50) { nodes { projectReviewId owner idea status latestGuidanceOutcome latestGuidance updatedAt } } }' \
  /tmp/van-pr.json &
pid3=$!

# Latest comments across all project reviews (for reply detection)
fetch 'query { allProjectReviewComments(condition:{hidden:false,tombstoned:false}, orderBy:TS_DESC, first:150) { nodes { projectReviewId author authorRole ts body } } }' \
  /tmp/van-pr-comments.json &
pid4=$!

# Latest guidance records (for coach interaction timestamps)
fetch 'query { allProjectReviewGuidances(condition:{hidden:false,tombstoned:false}, orderBy:TS_DESC, first:50) { nodes { projectReviewId reviewer outcome ts body } } }' \
  /tmp/van-pr-guidances.json &
pid5=$!

fetch 'query { allReviewSummaries(filter:{tombstoned:{equalTo:false}}, orderBy:UPDATED_AT_ASC, first:50) { nodes { programId reviewStatus submissionRevision updatedAt } } }' \
  /tmp/van-reviews.json &
pid6=$!

wait $pid1 $pid2 $pid3 $pid4 $pid5 $pid6

# ── Auto-update context files from on-chain data ────────────────────────────
# This keeps `auto` fields fresh (status, guidance, comment_count, etc.)
# without waiting for the LLM. The LLM fills `llm` fields.
jq -c '.data.allProjectReviewSummaries.nodes[]? | select(.projectReviewId != null)' /tmp/van-pr.json 2>/dev/null | while read -r node; do
  rid=$(echo "$node" | jq -r '.projectReviewId')
  # Find nickname or use review id
  nick=$(echo "$node" | jq -r '.idea[0:40]' | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g; s/[^a-z0-9-]//g; s/--*/-/g; s/^-\|-$//g' | cut -c1-30)
  ctx_file="$CONTEXT_DIR/$nick.json"
  if [ ! -f "$ctx_file" ]; then
    # Try by project_review_id
    ctx_file=$(grep -l "\"project_review_id\":.*\"$rid\"" "$CONTEXT_DIR"/*.json 2>/dev/null | head -1)
  fi
  if [ -f "$ctx_file" ]; then
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    existing=$(cat "$ctx_file")
    echo "$existing" | jq \
      --argjson node "$node" \
      --arg now "$now" \
      '.auto.status = ($node.status // .auto.status) |
       .auto.guidance = ($node.latestGuidanceOutcome // .auto.guidance) |
       .auto.comment_count = ($node.commentCount // .auto.comment_count) |
       .auto.linked_program_id = ($node.linkedProgramId // .auto.linked_program_id) |
       .auto.last_activity = $now' > "$ctx_file"
  fi
done
# Refresh index
context_index_refresh 2>/dev/null || true

# ── Extract current data ──────────────────────────────────────────────────────
CUR_MENTIONS=$(jq -r '.data.allChatMentions.nodes[]?.id // empty' /tmp/van-mentions.json | sort)
CUR_BODY_MENTIONS=$(jq -r '.data.allChatMessages.nodes[]?.id // empty' /tmp/van-chat-text.json | sort)
CUR_MENTIONS=$(printf '%s\n%s' "$CUR_MENTIONS" "$CUR_BODY_MENTIONS" | sort -u)

CUR_GUIDANCE=$(jq -r '.data.allProjectReviewSummaries.nodes[]? | select(.latestGuidanceOutcome == null or .latestGuidanceOutcome == "NeedsChanges") | "\(.projectReviewId)@\(.updatedAt)"' /tmp/van-pr.json | sort)

# ── Detect unanswered owner replies via timestamp comparison ──────────────────
# For each review, find:
#   coach_ts = max(latest guidance timestamp, latest coach comment timestamp)
#   owner_ts = latest owner comment timestamp
# If owner_ts > coach_ts → unanswered reply
#
# Build a list of {review}:{owner_ts}:{coach_ts} for reporting
CUR_REPLIES=""
# Get all review IDs the coach has guided
GUIDED_IDS=$(jq -r '.data.allProjectReviewGuidances.nodes[]?.projectReviewId // empty' /tmp/van-pr-guidances.json | sort -u)

if [ -n "$GUIDED_IDS" ]; then
  while IFS= read -r rid; do
    [ -z "$rid" ] && continue

    # Latest coach guidance timestamp for this review
    COACH_TS=$(jq -r --arg rid "$rid" --arg hex "$COACH_HEX" \
      '[.data.allProjectReviewGuidances.nodes[] | select(.projectReviewId == $rid and .reviewer == $hex) | .ts] | max // empty' \
      /tmp/van-pr-guidances.json)

    # Latest coach comment timestamp for this review (if any)
    COACH_COMMENT_TS=$(jq -r --arg rid "$rid" --arg hex "$COACH_HEX" \
      '[.data.allProjectReviewComments.nodes[] | select(.projectReviewId == $rid and .author == $hex) | .ts] | max // empty' \
      /tmp/van-pr-comments.json)

    # Latest owner comment timestamp
    OWNER_TS=$(jq -r --arg rid "$rid" --arg hex "$COACH_HEX" \
      '[.data.allProjectReviewComments.nodes[] | select(.projectReviewId == $rid and .author != $hex and .authorRole == "Owner") | .ts] | max // empty' \
      /tmp/van-pr-comments.json)

    if [ -n "$OWNER_TS" ] && [ -n "$COACH_TS" ] && [ "$OWNER_TS" -gt "$COACH_TS" ]; then
      CUR_REPLIES="${CUR_REPLIES}${rid}:${OWNER_TS}:${COACH_TS}"$'\n'
    elif [ -n "$OWNER_TS" ] && [ -z "$COACH_TS" ] && [ -n "$COACH_COMMENT_TS" ] && [ "$OWNER_TS" -gt "$COACH_COMMENT_TS" ]; then
      CUR_REPLIES="${CUR_REPLIES}${rid}:${OWNER_TS}:${COACH_COMMENT_TS}"$'\n'
    fi
  done <<< "$GUIDED_IDS"
  CUR_REPLIES=$(echo "$CUR_REPLIES" | sort)
fi

CUR_SUBMITTED=$(jq -r '.data.allReviewSummaries.nodes[]? | select(.reviewStatus == "Submitted" or .reviewStatus == "Commented" or .reviewStatus == "Requested") | "\(.programId)@\(.updatedAt)"' /tmp/van-reviews.json | sort)

# ── Load previous state ───────────────────────────────────────────────────────
LAST_SEEN_MENTIONS=""
LAST_SEEN_GUIDANCE=""
LAST_SEEN_REPLIES=""
LAST_SEEN_SUBMITTED=""
REPORTED_MENTIONS=""
REPORTED_GUIDANCE=""
REPORTED_REPLIES=""
REPORTED_SUBMITTED=""
REPORTED_AT=""
THREAD_HISTORY=""

if [ -f "$STATE_FILE" ]; then
  LAST_SEEN_MENTIONS=$(jq -r '.last_seen.mentions // ""' "$STATE_FILE")
  LAST_SEEN_GUIDANCE=$(jq -r '.last_seen.guidance // ""' "$STATE_FILE")
  LAST_SEEN_REPLIES=$(jq -r '.last_seen.replies // ""' "$STATE_FILE")
  LAST_SEEN_SUBMITTED=$(jq -r '.last_seen.submitted // ""' "$STATE_FILE")
  REPORTED_MENTIONS=$(jq -r '.reported.mentions // ""' "$STATE_FILE")
  REPORTED_GUIDANCE=$(jq -r '.reported.guidance // ""' "$STATE_FILE")
  REPORTED_REPLIES=$(jq -r '.reported.replies // ""' "$STATE_FILE")
  REPORTED_SUBMITTED=$(jq -r '.reported.submitted // ""' "$STATE_FILE")
  REPORTED_AT=$(jq -r '.reported_at // ""' "$STATE_FILE")
  THREAD_HISTORY=$(jq -r '.thread // ""' "$STATE_FILE")
fi

# ── Compute new items ─────────────────────────────────────────────────────────
NEW_MENTIONS=""
if [ -n "$CUR_MENTIONS" ]; then
  NEW_MENTIONS=$(comm -23 <(echo "$CUR_MENTIONS") <(echo "${REPORTED_MENTIONS:-}") 2>/dev/null || echo "$CUR_MENTIONS")
fi
NEW_GUIDANCE=""
if [ -n "$CUR_GUIDANCE" ]; then
  NEW_GUIDANCE=$(comm -23 <(echo "$CUR_GUIDANCE") <(echo "${REPORTED_GUIDANCE:-}") 2>/dev/null || echo "$CUR_GUIDANCE")
fi
NEW_REPLIES=""
if [ -n "$CUR_REPLIES" ]; then
  NEW_REPLIES=$(comm -23 <(echo "$CUR_REPLIES") <(echo "${REPORTED_REPLIES:-}") 2>/dev/null || echo "$CUR_REPLIES")
fi
NEW_SUBMITTED=""
if [ -n "$CUR_SUBMITTED" ]; then
  NEW_SUBMITTED=$(comm -23 <(echo "$CUR_SUBMITTED") <(echo "${REPORTED_SUBMITTED:-}") 2>/dev/null || echo "$CUR_SUBMITTED")
fi

# ── Save updated state ────────────────────────────────────────────────────────
NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

NEW_REPORTED_MENTIONS=""
if [ -n "$REPORTED_MENTIONS" ] && [ -n "$CUR_MENTIONS" ]; then
  NEW_REPORTED_MENTIONS=$(printf '%s\n%s' "$REPORTED_MENTIONS" "$CUR_MENTIONS" | sort -u)
elif [ -n "$CUR_MENTIONS" ]; then
  NEW_REPORTED_MENTIONS="$CUR_MENTIONS"
else
  NEW_REPORTED_MENTIONS="$REPORTED_MENTIONS"
fi

NEW_REPORTED_GUIDANCE=""
if [ -n "$REPORTED_GUIDANCE" ] && [ -n "$CUR_GUIDANCE" ]; then
  NEW_REPORTED_GUIDANCE=$(printf '%s\n%s' "$REPORTED_GUIDANCE" "$CUR_GUIDANCE" | sort -u)
elif [ -n "$CUR_GUIDANCE" ]; then
  NEW_REPORTED_GUIDANCE="$CUR_GUIDANCE"
else
  NEW_REPORTED_GUIDANCE="$REPORTED_GUIDANCE"
fi

NEW_REPORTED_REPLIES=""
if [ -n "$REPORTED_REPLIES" ] && [ -n "$CUR_REPLIES" ]; then
  NEW_REPORTED_REPLIES=$(printf '%s\n%s' "$REPORTED_REPLIES" "$CUR_REPLIES" | sort -u)
elif [ -n "$CUR_REPLIES" ]; then
  NEW_REPORTED_REPLIES="$CUR_REPLIES"
else
  NEW_REPORTED_REPLIES="$REPORTED_REPLIES"
fi

NEW_REPORTED_SUBMITTED=""
if [ -n "$REPORTED_SUBMITTED" ] && [ -n "$CUR_SUBMITTED" ]; then
  NEW_REPORTED_SUBMITTED=$(printf '%s\n%s' "$REPORTED_SUBMITTED" "$CUR_SUBMITTED" | sort -u)
elif [ -n "$CUR_SUBMITTED" ]; then
  NEW_REPORTED_SUBMITTED="$CUR_SUBMITTED"
else
  NEW_REPORTED_SUBMITTED="$REPORTED_SUBMITTED"
fi

jq -nc \
  --arg mentions "$CUR_MENTIONS" \
  --arg guidance "$CUR_GUIDANCE" \
  --arg replies "$CUR_REPLIES" \
  --arg submitted "$CUR_SUBMITTED" \
  --arg r_mentions "$NEW_REPORTED_MENTIONS" \
  --arg r_guidance "$NEW_REPORTED_GUIDANCE" \
  --arg r_replies "$NEW_REPORTED_REPLIES" \
  --arg r_submitted "$NEW_REPORTED_SUBMITTED" \
  --arg ts "$NOW_TS" \
  --arg thread "$THREAD_HISTORY" \
  '{
    last_seen: { mentions: $mentions, guidance: $guidance, replies: $replies, submitted: $submitted },
    reported: { mentions: $r_mentions, guidance: $r_guidance, replies: $r_replies, submitted: $r_submitted },
    reported_at: $ts,
    thread: $thread
  }' > "$STATE_FILE"

# ── Report only if genuinely NEW items ────────────────────────────────────────
if [ -z "$NEW_MENTIONS" ] && [ -z "$NEW_GUIDANCE" ] && [ -z "$NEW_REPLIES" ] && [ -z "$NEW_SUBMITTED" ]; then
  exit 0  # silent — nothing to report
fi

COUNT_MENTIONS=0
[ -n "$NEW_MENTIONS" ] && COUNT_MENTIONS=$(echo "$NEW_MENTIONS" | wc -l | tr -d ' ')
COUNT_GUIDANCE=0
[ -n "$NEW_GUIDANCE" ] && COUNT_GUIDANCE=$(echo "$NEW_GUIDANCE" | wc -l | tr -d ' ')
COUNT_REPLIES=0
[ -n "$NEW_REPLIES" ] && COUNT_REPLIES=$(echo "$NEW_REPLIES" | wc -l | tr -d ' ')
COUNT_SUBMITTED=0
[ -n "$NEW_SUBMITTED" ] && COUNT_SUBMITTED=$(echo "$NEW_SUBMITTED" | wc -l | tr -d ' ')

REPORT="## Cerberus Coach — New Items"

if [ "$COUNT_MENTIONS" -gt 0 ]; then
  REPORT+="

### 💬 New @cerberus mentions: $COUNT_MENTIONS"
  REPORT+=$'\n'"$(echo "$NEW_MENTIONS" | while read -r id; do
    msg=$(jq -r --arg id "$id" '.data.allChatMentions.nodes[] | select(.id == $id) | "Mention: \(.messageId) in block \(.substrateBlockNumber)"' /tmp/van-mentions.json 2>/dev/null)
    if [ -z "$msg" ]; then
      msg=$(jq -r --arg id "$id" '.data.allChatMessages.nodes[] | select(.id == $id) | "From @\(.authorHandle) (msgId \(.msgId), block \(.substrateBlockNumber)):\n\(.body)"' /tmp/van-chat-text.json 2>/dev/null)
    fi
    echo "  - $msg"
  done)"
fi

if [ "$COUNT_GUIDANCE" -gt 0 ]; then
  REPORT+="

### 📋 Project reviews needing guidance: $COUNT_GUIDANCE
Reviews with null or NeedsChanges guidance need coach attention."
  REPORT+=$'\n'"$(echo "$NEW_GUIDANCE" | head -5 | while read -r line; do echo "  - Review $line"; done)"
  if [ "$COUNT_GUIDANCE" -gt 5 ]; then
    REPORT+=$'\n'"  ... and $(($COUNT_GUIDANCE - 5)) more"
  fi
fi

if [ "$COUNT_REPLIES" -gt 0 ]; then
  REPORT+="

### 💬 Unanswered owner replies: $COUNT_REPLIES
Owner replied after the coach's last interaction — coach should re-engage."
  REPORT+=$'\n'"$(echo "$NEW_REPLIES" | while read -r line; do
    rid=$(echo "$line" | cut -d: -f1)
    detail=$(jq -r --arg rid "$rid" '.data.allProjectReviewSummaries.nodes[] | select(.projectReviewId == $rid) | "Review #\(.projectReviewId) — \(.idea[0:80]) — guidance: \(.latestGuidanceOutcome // "none")"' /tmp/van-pr.json 2>/dev/null)
    owner_body=$(jq -r --arg rid "$rid" --arg hex "$COACH_HEX" \
      '[.data.allProjectReviewComments.nodes[] | select(.projectReviewId == $rid and .author != $hex and .authorRole == "Owner")] | sort_by(.ts) | last | .body[0:200]' \
      /tmp/van-pr-comments.json 2>/dev/null)
    echo "  - $detail"
    if [ -n "$owner_body" ]; then
      echo "    Owner says: \"$owner_body\""
    fi
  done)"
fi

if [ "$COUNT_SUBMITTED" -gt 0 ]; then
  REPORT+="

### 🔍 New applications submitted for review: $COUNT_SUBMITTED
Apps in Submitted/Commented/Requested status need technical review."
  REPORT+=$'\n'"$(echo "$NEW_SUBMITTED" | head -5 | while read -r line; do echo "  - $line"; done)"
  if [ "$COUNT_SUBMITTED" -gt 5 ]; then
    REPORT+=$'\n'"  ... and $(($COUNT_SUBMITTED - 5)) more"
  fi
fi

# ── Load project context for continuity ──────────────────────────────────────
CONTEXT_BLOCK=""
ALL_RIDS=$(echo "$NEW_GUIDANCE $NEW_REPLIES" | tr ' ' '\n' | sed 's/@.*//' | sed 's/:.*//' | sort -u | tr -d ' ')

if [ -n "$ALL_RIDS" ]; then
  CONTEXT_BLOCK=$'\n\n---\n## Project Context (from ledger)\n'
  for rid in $ALL_RIDS; do
    [ -z "$rid" ] && continue
    # Resolve pr-{rid} to nickname via on-chain data
    nick=$(jq -r --arg rid "$rid" '.data.allProjectReviewSummaries.nodes[]? | select(.projectReviewId == $rid) | (.idea[0:40] // "unknown")' /tmp/van-pr.json 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g; s/[^a-z0-9-]//g; s/-\{2,\}/-/g; s/^-\|-$//g' | cut -c1-30)
    ctx_file="$CONTEXT_DIR/$nick.json"
    # Also look up by project_review_id in auto
    if [ ! -f "$ctx_file" ]; then
      # Try numeric project_review_id match
      ctx_file=$(grep -l "\"project_review_id\":.*\"$rid\"" "$CONTEXT_DIR"/*.json 2>/dev/null | head -1)
    fi
    # Fallback to pr-rid.json for backward compat
    if [ ! -f "$ctx_file" ]; then
      ctx_file="$CONTEXT_DIR/pr-$rid.json"
    fi
    
    if [ -f "$ctx_file" ]; then
      ctx=$(cat "$ctx_file")
      handle=$(echo "$ctx" | jq -r '.auto.handle // "pr-'"$rid"'"')
      maturity=$(echo "$ctx" | jq -r '.llm.maturity.level // "not assessed"')
      checklist=$(echo "$ctx" | jq -r '.llm.pre_approval_checklist // "not recorded"')
      items=$(echo "$ctx" | jq -r '.llm.open_items[]? // empty' | paste -sd '; ' - || echo "none")
      decisions=$(echo "$ctx" | jq -r '[.llm.decisions[]? | "\(.date): \(.action[0:60])"] | join(" | ") // "none"')
      CONTEXT_BLOCK+=$'\n'"### Review #$rid ($handle)"
      CONTEXT_BLOCK+=$'\n'"- Maturity: $maturity"
      CONTEXT_BLOCK+=$'\n'"- Checklist: $checklist"
      CONTEXT_BLOCK+=$'\n'"- Open items: $items"
      CONTEXT_BLOCK+=$'\n'"- Decisions: $decisions"
      CONTEXT_BLOCK+=$'\n'"- Context file: \`~/.cerberus/projects/$handle.json\`"
    else
      CONTEXT_BLOCK+=$'\n'"### Review #$rid (no context file)"
      handle="pr-$rid"
    fi
  done
  CONTEXT_BLOCK+=$'\n\n**After taking action, update the context file with write_file:**'
  CONTEXT_BLOCK+=$'\nUse write_file to \`~/.cerberus/projects/{handle}.json\` with updated .llm fields:'
  CONTEXT_BLOCK+=$'\n- maturity.level + reasoning'
  CONTEXT_BLOCK+=$'\n- blockchain_necessity'
  CONTEXT_BLOCK+=$'\n- pre_approval_checklist (step_0 through step_6)'
  CONTEXT_BLOCK+=$'\n- open_items'
  CONTEXT_BLOCK+=$'\n- decisions (append new entry)'
fi

# ── Load learned skills (self-learning) ──────────────────────────────────────
LEARNED_BLOCK=$(learned_load_all 2>/dev/null || echo "")
if [ -n "$LEARNED_BLOCK" ]; then
  REPORT+="

$LEARNED_BLOCK"
fi

REPORT+="$CONTEXT_BLOCK"

# ── Self-learning instructions (after context, so LLM has full picture) ──────
REPORT+="

## 📚 Self-Learning — Capture New Patterns

If this session reveals a **recurring pattern** not covered by the learned skills above:

1. **Recognize** — a new red flag variant, a guidance template that works well, an archetype of project you haven't classified before
2. **Distill** — write a concise markdown file with YAML frontmatter (description:, name:), a ## Procedure section, and ## Gotchas section
3. **Capture** — use write_file to save it to ~/.cerberus/learned/<short-name>.md

Only create a new learned skill when the pattern is **verified** (you acted on it, the owner responded, and it proved useful) — don't enshrine guesses. A one-off anomaly goes into the project context, not into learned/."



# Update thread history (keep last 3)
NEW_THREAD=$(printf '%s\n%s' "[$NOW_TS] $COUNT_MENTIONS mentions, $COUNT_GUIDANCE reviews, $COUNT_REPLIES replies, $COUNT_SUBMITTED apps" "$THREAD_HISTORY" | head -3)

jq -nc \
  --arg mentions "$CUR_MENTIONS" \
  --arg guidance "$CUR_GUIDANCE" \
  --arg replies "$CUR_REPLIES" \
  --arg submitted "$CUR_SUBMITTED" \
  --arg r_mentions "$NEW_REPORTED_MENTIONS" \
  --arg r_guidance "$NEW_REPORTED_GUIDANCE" \
  --arg r_replies "$NEW_REPORTED_REPLIES" \
  --arg r_submitted "$NEW_REPORTED_SUBMITTED" \
  --arg ts "$NOW_TS" \
  --arg thread "$NEW_THREAD" \
  '{
    last_seen: { mentions: $mentions, guidance: $guidance, replies: $replies, submitted: $submitted },
    reported: { mentions: $r_mentions, guidance: $r_guidance, replies: $r_replies, submitted: $r_submitted },
    reported_at: $ts,
    thread: $thread
  }' > "$STATE_FILE"

echo "$REPORT"
