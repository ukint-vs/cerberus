#!/usr/bin/env bash
# Foundation Reviewer — review lane watchdog
# Detects new Submitted/Commented/Requested applications and outputs
# a structured context package for the LLM reviewer.
#
# Tracks programId@submissionRevision pairs so repeated submissions
# (new revisions) get re-reviewed while already-processed ones are skipped.
#
# Designed for cronjob with no_agent=False (script stdout → LLM context).

set -euo pipefail

VAN_DIR="${VARA_AGENT_NETWORK_SKILLS_DIR:-}"
if [ -z "$VAN_DIR" ]; then
  for d in "$HOME/.hermes/skills/vara-agent-network-skills" "$HOME/.agents/skills/vara-agent-network-skills"; do
    if [ -d "$d/idl" ]; then VAN_DIR="$d"; break; fi
  done
fi
if [ ! -d "$VAN_DIR/idl" ]; then
  exit 0
fi

eval "$(awk '/^```bash$/{f=1; next} /^```$/{if(f) exit} f' "$VAN_DIR/references/program-ids.md")"

INDEXER="$INDEXER_GRAPHQL_URL"
STATE_FILE="/tmp/van-reviewer-state.json"
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

# ── Step 1: Fetch review summaries ───────────────────────────────────────────
fetch 'query { allReviewSummaries(filter:{tombstoned:{equalTo:false}},orderBy:UPDATED_AT_DESC,first:50) {
  nodes {
    programId reviewStatus displayRevision submissionRevision
    activeRequestRevision activeRequestAcknowledged latestVerdict latestReason
    manualOverride updatedAt
  }
}}' /tmp/van-rs.json &

# Also fetch project reviews (pre-deploy) — Submitted items with no guidance, or NeedsChanges items
fetch 'query { allProjectReviewSummaries(condition:{hidden:false,tombstoned:false},orderBy:UPDATED_AT_DESC,first:50) {
  nodes { projectReviewId owner githubUrl idea status linkedProgramId
          latestGuidanceOutcome latestGuidance latestReviewer commentCount updatedAt }
}}' /tmp/van-pr-summaries.json &

wait

# ── Step 2: Parse items needing review ───────────────────────────────────────
# Priority order: Requested > Submitted > Commented
# Track key: programId@submissionRevision
CUR_NEEDS_REVIEW=$(jq -r '
  .data.allReviewSummaries.nodes[]?
  | select(.reviewStatus == "Submitted" or .reviewStatus == "Commented" or .reviewStatus == "Requested")
  | "\(.programId)@\(.submissionRevision // 0)@\(.reviewStatus)"
' /tmp/van-rs.json | sort -u)

CUR_SUBMITTED=$(echo "$CUR_NEEDS_REVIEW" | grep "@Submitted$" || true)
CUR_REQUESTED=$(echo "$CUR_NEEDS_REVIEW" | grep "@Requested$" || true)
CUR_COMMENTED=$(echo "$CUR_NEEDS_REVIEW" | grep "@Commented$" || true)

# ── Step 3: Load state ────────────────────────────────────────────────────────
LAST_SEEN_SUBMITTED=""
LAST_SEEN_REQUESTED=""
LAST_SEEN_COMMENTED=""
REPORTED_SUBMITTED=""
REPORTED_REQUESTED=""
REPORTED_COMMENTED=""
REPORTED_AT=""

if [ -f "$STATE_FILE" ]; then
  LAST_SEEN_SUBMITTED=$(jq -r '.last_seen.submitted // ""' "$STATE_FILE")
  LAST_SEEN_REQUESTED=$(jq -r '.last_seen.requested // ""' "$STATE_FILE")
  LAST_SEEN_COMMENTED=$(jq -r '.last_seen.commented // ""' "$STATE_FILE")
  REPORTED_SUBMITTED=$(jq -r '.reported.submitted // ""' "$STATE_FILE")
  REPORTED_REQUESTED=$(jq -r '.reported.requested // ""' "$STATE_FILE")
  REPORTED_COMMENTED=$(jq -r '.reported.commented // ""' "$STATE_FILE")
  REPORTED_AT=$(jq -r '.reported_at // ""' "$STATE_FILE")
fi

# ── Step 4: Compute new items ────────────────────────────────────────────────
NEW_SUBMITTED=""
if [ -n "$CUR_SUBMITTED" ]; then
  if [ -n "$REPORTED_SUBMITTED" ]; then
    NEW_SUBMITTED=$(comm -23 <(echo "$CUR_SUBMITTED") <(echo "$REPORTED_SUBMITTED") 2>/dev/null || echo "$CUR_SUBMITTED")
  else
    NEW_SUBMITTED="$CUR_SUBMITTED"
  fi
fi

NEW_REQUESTED=""
if [ -n "$CUR_REQUESTED" ]; then
  if [ -n "$REPORTED_REQUESTED" ]; then
    NEW_REQUESTED=$(comm -23 <(echo "$CUR_REQUESTED") <(echo "$REPORTED_REQUESTED") 2>/dev/null || echo "$CUR_REQUESTED")
  else
    NEW_REQUESTED="$CUR_REQUESTED"
  fi
fi

NEW_COMMENTED=""
if [ -n "$CUR_COMMENTED" ]; then
  if [ -n "$REPORTED_COMMENTED" ]; then
    NEW_COMMENTED=$(comm -23 <(echo "$CUR_COMMENTED") <(echo "$REPORTED_COMMENTED") 2>/dev/null || echo "$CUR_COMMENTED")
  else
    NEW_COMMENTED="$CUR_COMMENTED"
  fi
fi

# ── Step 5: If nothing new, exit silent ──────────────────────────────────────
if [ -z "$NEW_SUBMITTED" ] && [ -z "$NEW_REQUESTED" ] && [ -z "$NEW_COMMENTED" ]; then
  # Still save current as last_seen
  NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -nc \
    --arg s "$CUR_SUBMITTED" \
    --arg rq "$CUR_REQUESTED" \
    --arg c "$CUR_COMMENTED" \
    --arg rs "$REPORTED_SUBMITTED" \
    --arg rrq "$REPORTED_REQUESTED" \
    --arg rc "$REPORTED_COMMENTED" \
    --arg ts "$NOW_TS" \
    '{last_seen:{submitted:$s,requested:$rq,commented:$c},reported:{submitted:$rs,requested:$rrq,commented:$rc},reported_at:$ts}' > "$STATE_FILE"
  exit 0
fi

# ── Step 6: Fetch context for each new item ──────────────────────────────────
REPORT="## Foundation Review Lane — New Items"

# ── Load coach's learned skills (consistency with coach) ──────────────────────
LEARNED_BLOCK=$(learned_load_all 2>/dev/null || echo "")
if [ -n "$LEARNED_BLOCK" ]; then
  REPORT+="

$LEARNED_BLOCK

**Note:** These are learned patterns accumulated by @cerberus (coach).
As the Foundation reviewer, you inherit this knowledge to maintain
publish-consistency with the coach's evaluations."

fi

# Collect program IDs to fetch their details
ALL_PROGRAM_IDS=$(echo "$NEW_SUBMITTED $NEW_REQUESTED $NEW_COMMENTED" | tr ' ' '\n' | sed 's/@.*//' | sort -u)

for PROG_ID in $ALL_PROGRAM_IDS; do
  # Fetch application details
  fetch "query { applicationById(id: \"$PROG_ID\") { id handle githubUrl status owner } }" \
    "/tmp/van-app-$PROG_ID.json"

  # Fetch review thread
  fetch "query { allReviewRequests(condition:{programId:\"$PROG_ID\"}) { nodes { revision reason requestedAt acknowledged } } allReviewComments(condition:{programId:\"$PROG_ID\",hidden:false,tombstoned:false},orderBy:TS_ASC) { nodes { revision author authorRole body ts } } allReviewDecisions(condition:{programId:\"$PROG_ID\",tombstoned:false},orderBy:DECIDED_AT_ASC) { nodes { revision reviewer verdict reason oldStatus newStatus decidedAt } } }" \
    "/tmp/van-review-thread-$PROG_ID.json"

  # Get app handle for chat lookup
  APP_HANDLE=$(jq -r '.data.applicationById?.handle // ""' "/tmp/van-app-$PROG_ID.json")
  APP_GITHUB=$(jq -r '.data.applicationById?.githubUrl // ""' "/tmp/van-app-$PROG_ID.json")
  APP_OWNER=$(jq -r '.data.applicationById?.owner // ""' "/tmp/van-app-$PROG_ID.json")
  APP_STATUS=$(jq -r '.data.applicationById?.status // "unknown"' "/tmp/van-app-$PROG_ID.json")
  APP_JOINED=""

  # Fetch last 10 chat messages from this app's handle
  if [ -n "$APP_HANDLE" ]; then
    fetch "query { allChatMessages(first:10,orderBy:SUBSTRATE_BLOCK_NUMBER_DESC,filter:{authorHandle:{equalTo:\"$APP_HANDLE\"}}) { nodes { id msgId authorHandle body substrateBlockNumber } } }" \
      "/tmp/van-chat-$PROG_ID.json"

    # Also fetch messages FROM cerberus TO this handle (coaching replies)
    # Use subquery — chat messages where body contains @handle
    fetch "query { allChatMessages(first:10,orderBy:SUBSTRATE_BLOCK_NUMBER_DESC,filter:{body:{includes:\"@$APP_HANDLE\"}}) { nodes { id msgId authorHandle body substrateBlockNumber } } }" \
      "/tmp/van-coach-$PROG_ID.json"
  fi

  # Check which lanes this program appears in
  REVIEW_LANES=""
  if [[ $'\n'"$NEW_SUBMITTED"$'\n' == *$'\n'"$PROG_ID@"* ]]; then
    REVIEW_LANES="${REVIEW_LANES}Submitted "
  fi
  if [[ $'\n'"$NEW_REQUESTED"$'\n' == *$'\n'"$PROG_ID@"* ]]; then
    REVIEW_LANES="${REVIEW_LANES}Requested "
  fi
  if [[ $'\n'"$NEW_COMMENTED"$'\n' == *$'\n'"$PROG_ID@"* ]]; then
    REVIEW_LANES="${REVIEW_LANES}Commented "
  fi

  # Get the review summary for this program
  fetch "query { reviewSummaryByProgramId(programId:\"$PROG_ID\") { programId reviewStatus manualOverride displayRevision submissionRevision activeRequestRevision latestVerdict latestReason } }" \
    "/tmp/van-rs-summary-$PROG_ID.json"

  # Get linked project review (if any)
  PROJECT_REVIEW_ID=$(jq -r --arg prog "$PROG_ID" '.data.allProjectReviewSummaries.nodes[]? | select(.linkedProgramId == $prog) | .projectReviewId' /tmp/van-pr-summaries.json 2>/dev/null | head -1 || true)
  if [ -n "$PROJECT_REVIEW_ID" ]; then
    fetch "query { allProjectReviewSummaries(condition:{projectReviewId:\"$PROJECT_REVIEW_ID\",hidden:false,tombstoned:false},first:1) { nodes { projectReviewId owner githubUrl idea status latestGuidanceOutcome latestGuidance linkedProgramId } } }" \
      "/tmp/van-pr-$PROG_ID.json"
  fi

  # ── Build report section ──────────────────────────────────────────────────
  REPORT+="

### 📦 Application: $APP_HANDLE
\`\`\`
Program:    $PROG_ID
Status:     $APP_STATUS
Owner:      $APP_OWNER
GitHub:     $APP_GITHUB
Joined:     $APP_JOINED
Lane:       ${REVIEW_LANES:-unknown}
\`\`\`

**Review summary (indexer):**
\`\`\`
$(jq -r '.data.reviewSummaryByProgramId | {reviewStatus, displayRevision, submissionRevision, latestVerdict, latestReason} | to_entries | map("\(.key): \(.value // \"null\")") | .[]' "/tmp/van-rs-summary-$PROG_ID.json" 2>/dev/null || echo "  (unavailable)")
\`\`\`

**Review request history:**
$(jq -r '.data.allReviewRequests.nodes[]? | "  - Rev \(.revision): \(.reason)[\(.requestedAt)]\(if .acknowledged then " ✅ acknowledged" else " ⏳ pending" end)"' "/tmp/van-review-thread-$PROG_ID.json" 2>/dev/null || echo "  (none)")

**Reviewer comments:**
$(jq -r '.data.allReviewComments.nodes[]? | "  - [Rev \(.revision)] **\(.author)**: \(.body)"' "/tmp/van-review-thread-$PROG_ID.json" 2>/dev/null || echo "  (none)")

**Decision history:**
$(jq -r '.data.allReviewDecisions.nodes[]? | "  - [Rev \(.revision)] \(.verdict) by \(.reviewer): \(.reason)"' "/tmp/van-review-thread-$PROG_ID.json" 2>/dev/null || echo "  (none)")"

  # Coach chat history
  CHAT_MSGS=$(jq -r '.data.allChatMessages.nodes[]? | "  [Block \(.substrateBlockNumber)] @\(.authorHandle): \(.body | .[0:200])..."' "/tmp/van-chat-$PROG_ID.json" 2>/dev/null || echo "  (none)")
  COACH_MSGS=$(jq -r '.data.allChatMessages.nodes[]? | "  [Block \(.substrateBlockNumber)] @\(.authorHandle): \(.body | .[0:200])..."' "/tmp/van-coach-$PROG_ID.json" 2>/dev/null || echo "  (none)")

  REPORT+="
**Last 10 messages from @$APP_HANDLE:**
${CHAT_MSGS:-  (none)}

**Last 10 coaching replies mentioning @$APP_HANDLE:**
${COACH_MSGS:-  (none)}"

  # Linked project review
  if [ -f "/tmp/van-pr-$PROG_ID.json" ]; then
    PR_INFO=$(jq -r '.data.allProjectReviewSummaries.nodes[0]? | "  Project: \(.idea | .[0:100])...\n  Guidance: \(.latestGuidanceOutcome // "none") — \(.latestGuidance // "")\n  GitHub: \(.githubUrl)"' "/tmp/van-pr-$PROG_ID.json" 2>/dev/null)
    if [ -n "$PR_INFO" ]; then
      REPORT+="
**Linked project review (Stage 1/2a coaching):**
${PR_INFO}"
    fi
  fi

  # Coach's project context (ledger)
  COACH_CTX=$(jq -r '.data.allProjectReviewSummaries.nodes[0]?.projectReviewId // empty' "/tmp/van-pr-$PROG_ID.json" 2>/dev/null || true)
  if [ -n "$COACH_CTX" ]; then
    # Find context file by project_review_id
    ctx_file=$(grep -l "\"project_review_id\":.*\"$COACH_CTX\"" "$CONTEXT_DIR"/*.json 2>/dev/null | head -1 || true)
    if [ -n "$ctx_file" ]; then
      ctx=$(cat "$ctx_file")
      maturity=$(echo "$ctx" | jq -r '.llm.maturity.level // "not recorded"')
      checklist=$(echo "$ctx" | jq -r '.llm.pre_approval_checklist // "not recorded"')
      items=$(echo "$ctx" | jq -r '.llm.open_items[]? // empty' | paste -sd '; ' - || echo "none")
      bcn=$(echo "$ctx" | jq -r '.llm.blockchain_necessity // "not recorded"')
      REPORT+="
**Coach's project context (from ledger):**
- Maturity: $maturity
- Blockchain necessity: $bcn
- Pre-approval checklist: $checklist
- Open items: $items"
    fi
  fi

  # GitHub code review prompt
  if [ -n "$APP_GITHUB" ] && [ "$APP_GITHUB" != "null" ]; then
    REPORT+="
**GitHub for code review:** $APP_GITHUB"
  fi

  REPORT+="
---
"
done

# ── Step 7: Check project reviews (pre-deploy) ──────────────────────────────
# List project reviews needing review: Submitted with no guidance, or NeedsChanges
PR_NEEDING_REVIEW=$(jq -r '.data.allProjectReviewSummaries.nodes[]?
  | select(.status == "Submitted" and .latestGuidanceOutcome == null)
  | "🔴 New: PR#\(.projectReviewId) by \(.owner[0:20]) — \(.idea[0:60])..."
' /tmp/van-pr-summaries.json 2>/dev/null)

PR_NEEDS_CHANGES=$(jq -r '.data.allProjectReviewSummaries.nodes[]?
  | select(.latestGuidanceOutcome == "NeedsChanges")
  | "🟡 Needs re-review: PR#\(.projectReviewId) by \(.owner[0:20]) — \(.idea[0:60])..."
' /tmp/van-pr-summaries.json 2>/dev/null)

if [ -n "$PR_NEEDING_REVIEW" ] || [ -n "$PR_NEEDS_CHANGES" ]; then
  REPORT+="

## 📋 Project Reviews (pre-deploy)"

  if [ -n "$PR_NEEDING_REVIEW" ]; then
    REPORT+="

### New submissions needing Stage 1 review:
$PR_NEEDING_REVIEW"
    # Fetch full details for each new PR
    echo "$PR_NEEDING_REVIEW" | while read -r line; do
      PR_ID=$(echo "$line" | sed 's/.*PR#\([0-9]*\).*/\1/')
      fetch "query { allProjectReviewSummaries(condition:{projectReviewId:\"$PR_ID\",hidden:false,tombstoned:false},first:1) { nodes { projectReviewId owner githubUrl idea status linkedProgramId latestGuidanceOutcome latestGuidance commentCount } } allProjectReviewComments(condition:{projectReviewId:\"$PR_ID\",hidden:false,tombstoned:false},orderBy:TS_ASC,first:50) { nodes { author authorRole body ts } } allProjectReviewGuidances(condition:{projectReviewId:\"$PR_ID\",hidden:false,tombstoned:false},orderBy:TS_ASC,first:10) { nodes { reviewer outcome body ts } } }" \
        "/tmp/van-pr-detail-$PR_ID.json"

      PR_OWNER=$(jq -r '.data.allProjectReviewSummaries.nodes[0]?.owner // "unknown"' "/tmp/van-pr-detail-$PR_ID.json")
      PR_GITHUB=$(jq -r '.data.allProjectReviewSummaries.nodes[0]?.githubUrl // "none"' "/tmp/van-pr-detail-$PR_ID.json")
      PR_IDEA=$(jq -r '.data.allProjectReviewSummaries.nodes[0]?.idea // ""' "/tmp/van-pr-detail-$PR_ID.json")
      
      # Fetch chat context for the owner
      if [ -n "$PR_OWNER" ] && [ "$PR_OWNER" != "unknown" ]; then
        gql_handle="query { allParticipants(filter:{id:{equalTo:\"$PR_OWNER\"}}) { nodes { handle } } }"
        fetch "$gql_handle" "/tmp/van-pr-owner-$PR_ID.json"
        PR_HANDLE=$(jq -r '.data.allParticipants.nodes[0]?.handle // ""' "/tmp/van-pr-owner-$PR_ID.json")
        if [ -n "$PR_HANDLE" ]; then
          fetch "query { allChatMessages(first:10,orderBy:SUBSTRATE_BLOCK_NUMBER_DESC,filter:{authorHandle:{equalTo:\"$PR_HANDLE\"}}) { nodes { authorHandle body substrateBlockNumber } } }" \
            "/tmp/van-pr-chat-$PR_ID.json"
          fetch "query { allChatMessages(first:10,orderBy:SUBSTRATE_BLOCK_NUMBER_DESC,filter:{body:{includes:\"@$PR_HANDLE\"}}) { nodes { authorHandle body substrateBlockNumber } } }" \
            "/tmp/van-pr-coach-$PR_ID.json"
        fi
      fi

      REPORT+="

### PR #$PR_ID — Owner: ${PR_HANDLE:-$PR_OWNER}
**Idea:** ${PR_IDEA:0:200}...
**GitHub:** $PR_GITHUB

**Review thread:**"
      PR_COMMENTS=$(jq -r '.data.allProjectReviewComments.nodes[]? | "  - @\(.author): \(.body[0:200])"' "/tmp/van-pr-detail-$PR_ID.json" 2>/dev/null || echo "  (none)")
      REPORT+="
${PR_COMMENTS}"
      PR_GUIDANCES=$(jq -r '.data.allProjectReviewGuidances.nodes[]? | "  - Guidance: \(.outcome) by \(.reviewer): \(.body[0:100])"' "/tmp/van-pr-detail-$PR_ID.json" 2>/dev/null || echo "  (none)")
      REPORT+="
${PR_GUIDANCES}"

      # Chat context
      PR_CHAT=$(jq -r '.data.allChatMessages.nodes[]? | "  [\(.substrateBlockNumber)] @\(.authorHandle): \(.body[0:150])"' "/tmp/van-pr-chat-$PR_ID.json" 2>/dev/null || echo "  (none)")
      PR_COACH=$(jq -r '.data.allChatMessages.nodes[]? | "  [\(.substrateBlockNumber)] @\(.authorHandle): \(.body[0:150])"' "/tmp/van-pr-coach-$PR_ID.json" 2>/dev/null || echo "  (none)")
      REPORT+="
**Last 10 messages from builder:**
${PR_CHAT}
**Last 10 coaching replies:**
${PR_COACH}
---
"
    done
  fi

  if [ -n "$PR_NEEDS_CHANGES" ]; then
    REPORT+="

### Reviews awaiting re-submission after NeedsChanges:
$PR_NEEDS_CHANGES"
  fi
fi

# ── Step 8: Update state ────────────────────────────────────────────────────
NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

NEW_REPORTED_SUBMITTED=""
if [ -n "$REPORTED_SUBMITTED" ] && [ -n "$CUR_SUBMITTED" ]; then
  NEW_REPORTED_SUBMITTED=$(printf '%s\n%s' "$REPORTED_SUBMITTED" "$CUR_SUBMITTED" | sort -u)
elif [ -n "$CUR_SUBMITTED" ]; then
  NEW_REPORTED_SUBMITTED="$CUR_SUBMITTED"
else
  NEW_REPORTED_SUBMITTED="$REPORTED_SUBMITTED"
fi

NEW_REPORTED_REQUESTED=""
if [ -n "$REPORTED_REQUESTED" ] && [ -n "$CUR_REQUESTED" ]; then
  NEW_REPORTED_REQUESTED=$(printf '%s\n%s' "$REPORTED_REQUESTED" "$CUR_REQUESTED" | sort -u)
elif [ -n "$CUR_REQUESTED" ]; then
  NEW_REPORTED_REQUESTED="$CUR_REQUESTED"
else
  NEW_REPORTED_REQUESTED="$REPORTED_REQUESTED"
fi

NEW_REPORTED_COMMENTED=""
if [ -n "$REPORTED_COMMENTED" ] && [ -n "$CUR_COMMENTED" ]; then
  NEW_REPORTED_COMMENTED=$(printf '%s\n%s' "$REPORTED_COMMENTED" "$CUR_COMMENTED" | sort -u)
elif [ -n "$CUR_COMMENTED" ]; then
  NEW_REPORTED_COMMENTED="$CUR_COMMENTED"
else
  NEW_REPORTED_COMMENTED="$REPORTED_COMMENTED"
fi

jq -nc \
  --arg s "$CUR_SUBMITTED" \
  --arg rq "$CUR_REQUESTED" \
  --arg c "$CUR_COMMENTED" \
  --arg rs "$NEW_REPORTED_SUBMITTED" \
  --arg rrq "$NEW_REPORTED_REQUESTED" \
  --arg rc "$NEW_REPORTED_COMMENTED" \
  --arg ts "$NOW_TS" \
  '{
    last_seen: {submitted:$s,requested:$rq,commented:$c},
    reported: {submitted:$rs,requested:$rrq,commented:$rc},
    reported_at:$ts
  }' > "$STATE_FILE"

echo "$REPORT"
