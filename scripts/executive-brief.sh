#!/usr/bin/env bash
# Executive Brief — pulls data from Tableau, Zendesk, and Billing A2A
# to generate C-suite ready account narratives.
# Output: formatted brief to stdout (or file with --output)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Defaults ---
CONFIG_PATH="${CONFIG_PATH:-./config/config.json}"
DRY_RUN="${DRY_RUN:-false}"
OUTPUT_FILE=""
CUSTOMER_FILTER=""
DAYS=""
SECTIONS_FILTER=""

# --- Flags ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --customer)  CUSTOMER_FILTER="$2"; shift 2 ;;
    --days)      DAYS="$2"; shift 2 ;;
    --output)    OUTPUT_FILE="$2"; shift 2 ;;
    --dry-run)   DRY_RUN="true"; shift ;;
    --sections)  SECTIONS_FILTER="$2"; shift 2 ;;
    *)           echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# --- Dependency checks ---
for cmd in jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required. Install with: brew install $cmd" >&2
    exit 1
  fi
done

# --- Config validation ---
if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found at $CONFIG_PATH" >&2
  echo "Copy config/example-config.json to config/config.json and fill in your data." >&2
  exit 1
fi

if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
  echo "ERROR: $CONFIG_PATH is not valid JSON" >&2
  exit 1
fi

missing_fields=()
if [[ "$(jq 'has("customers") and (.customers | type == "array")' "$CONFIG_PATH")" != "true" ]]; then
  missing_fields+=("customers (array)")
fi
if [[ "$(jq 'has("tableau")' "$CONFIG_PATH")" != "true" ]]; then
  missing_fields+=("tableau")
fi
if [[ "$(jq 'has("zendesk")' "$CONFIG_PATH")" != "true" ]]; then
  missing_fields+=("zendesk")
fi
if [[ ${#missing_fields[@]} -gt 0 ]]; then
  echo "ERROR: Config missing required fields: ${missing_fields[*]}" >&2
  exit 1
fi

# --- Read config ---
TABLEAU_SERVER=$(jq -r '.tableau.server // ""' "$CONFIG_PATH" | sed 's|^https://||')
TABLEAU_SITE=$(jq -r '.tableau.site' "$CONFIG_PATH")
TABLEAU_API=$(jq -r '.tableau.api_version // "3.24"' "$CONFIG_PATH")
TABLEAU_PAT_NAME=$(jq -r '.tableau.pat_name' "$CONFIG_PATH")
TABLEAU_PAT_SECRET="${TABLEAU_PAT_SECRET:-}"
TABLEAU_VIEW_ID=$(jq -r '.tableau.revenue_view_id' "$CONFIG_PATH")

ZD_SUBDOMAIN=$(jq -r '.zendesk.subdomain' "$CONFIG_PATH")
ZD_EMAIL=$(jq -r '.zendesk.email' "$CONFIG_PATH")
ZD_TOKEN="${ZENDESK_API_TOKEN:-}"

A2A_URL=$(jq -r '.a2a.billing_url // empty' "$CONFIG_PATH" 2>/dev/null || true)
A2A_URL="${A2A_URL:-http://revenue-agents.query.prod.telnyx.io:8000/a2a/billing-account/rpc}"

DEFAULT_DAYS=$(jq -r '.output.default_days // 90' "$CONFIG_PATH")
DAYS="${DAYS:-$DEFAULT_DAYS}"
OUTPUT_FORMAT=$(jq -r '.output.format // "text"' "$CONFIG_PATH")

# Sections to include
if [[ -n "$SECTIONS_FILTER" ]]; then
  SECTIONS="$SECTIONS_FILTER"
else
  SECTIONS=$(jq -r '.output.sections // ["tldr","revenue","support","risks","opportunities","actions"] | join(",")' "$CONFIG_PATH")
fi

CUSTOMER_COUNT=$(jq '.customers | length' "$CONFIG_PATH")

echo "📊 Executive Brief Generator" >&2
echo "   Config: $CONFIG_PATH ($CUSTOMER_COUNT customers)" >&2
echo "   Days: $DAYS | Sections: $SECTIONS | Format: $OUTPUT_FORMAT" >&2
[[ "$DRY_RUN" == "true" ]] && echo "   🧪 DRY RUN MODE — no external calls" >&2
echo "" >&2

# --- Read Slack config ---
SLACK_CHANNEL=$(jq -r '.slack.channel // empty' "$CONFIG_PATH" 2>/dev/null || true)

# --- Extract helpers (same pattern as EOM Credit Check) ---
# Usage: extract_number "response text" "keyword1|keyword2"
extract_number() {
  local text="$1" pattern="$2"
  echo "$text" | grep -ioE "${pattern}[^0-9\$-]{0,20}[-\$]{0,2}[0-9,]+\.?[0-9]*" | head -1 | \
    grep -oE '[-]?\$?[0-9,]+\.?[0-9]*' | tail -1 | tr -d '$,' || echo ""
}

extract_bool() {
  local text="$1" pattern="$2"
  local snippet
  snippet=$(echo "$text" | grep -ioE "${pattern}[^.]{0,40}" | head -1 || echo "")
  if echo "$snippet" | grep -iqE '(yes|true|enabled|active|has auto|with auto)'; then
    echo "true"
  elif echo "$snippet" | grep -iqE '(no|false|disabled|inactive|no auto|without auto)'; then
    echo "false"
  else
    if echo "$text" | grep -iqE "(${pattern}).{0,20}(yes|true|enabled|active)"; then
      echo "true"
    else
      echo "false"
    fi
  fi
}

# --- Retry wrapper ---
retry_curl() {
  local attempt=1 max=3 delay=2
  while true; do
    local output
    output=$(curl --connect-timeout 10 --max-time 30 -s "$@" 2>/dev/null) && { echo "$output"; return 0; }
    if [[ $attempt -ge $max ]]; then
      echo '{"error":"request_failed"}'; return 1
    fi
    echo "  Retry $attempt/$max after ${delay}s..." >&2
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# --- Tableau auth ---
TABLEAU_TOKEN=""
TABLEAU_SITE_ID=""

tableau_auth() {
  if [[ -z "$TABLEAU_PAT_SECRET" || -z "$TABLEAU_PAT_NAME" || "$TABLEAU_PAT_NAME" == "null" ]]; then
    echo "  ⚠️  Tableau PAT not configured, will use A2A fallback" >&2
    return 1
  fi
  local payload
  payload=$(jq -n \
    --arg name "$TABLEAU_PAT_NAME" \
    --arg secret "$TABLEAU_PAT_SECRET" \
    --arg site "$TABLEAU_SITE" \
    '{credentials: {personalAccessTokenName: $name, personalAccessTokenSecret: $secret, site: {contentUrl: $site}}}')

  local response
  response=$(retry_curl -X POST \
    "https://${TABLEAU_SERVER}/api/${TABLEAU_API}/auth/signin" \
    -H "Content-Type: application/json" \
    -d "$payload") || { echo "  ⚠️  Tableau auth failed" >&2; return 1; }

  TABLEAU_TOKEN=$(echo "$response" | jq -r '.credentials.token // empty' 2>/dev/null)
  TABLEAU_SITE_ID=$(echo "$response" | jq -r '.credentials.site.id // empty' 2>/dev/null)

  if [[ -z "$TABLEAU_TOKEN" ]]; then
    echo "  ⚠️  Tableau auth returned no token" >&2
    return 1
  fi
  echo "  ✅ Tableau authenticated" >&2
  return 0
}

# --- Fetch revenue from Tableau ---
fetch_tableau_revenue() {
  local customer_name="$1"
  local encoded_name
  encoded_name=$(jq -rn --arg s "$customer_name" '$s | @uri')

  local response http_code output
  output=$(curl --connect-timeout 10 --max-time 30 -s -w "\n%{http_code}" \
    "https://${TABLEAU_SERVER}/api/${TABLEAU_API}/sites/${TABLEAU_SITE_ID}/views/${TABLEAU_VIEW_ID}/data?vf_Account+Name=${encoded_name}" \
    -H "X-Tableau-Auth: ${TABLEAU_TOKEN}" 2>/dev/null) || true
  http_code=$(echo "$output" | tail -1)
  response=$(echo "$output" | sed '$d')

  # Re-auth on 401 and retry once
  if [[ "$http_code" == "401" ]]; then
    echo "  🔄 Tableau 401 — re-authenticating..." >&2
    if tableau_auth; then
      response=$(retry_curl \
        "https://${TABLEAU_SERVER}/api/${TABLEAU_API}/sites/${TABLEAU_SITE_ID}/views/${TABLEAU_VIEW_ID}/data?vf_Account+Name=${encoded_name}" \
        -H "X-Tableau-Auth: ${TABLEAU_TOKEN}") || return 1
    else
      return 1
    fi
  elif [[ ! "$http_code" =~ ^2 ]]; then
    return 1
  fi

  echo "$response"
}

# --- Fetch data from Billing A2A ---
a2a_query() {
  local query="$1"
  local msg_id="exec-brief-$(date +%s)-$RANDOM"

  local payload
  payload=$(jq -n \
    --arg mid "$msg_id" \
    --arg query "$query" \
    '{
      jsonrpc: "2.0",
      id: $mid,
      method: "message/send",
      params: {
        message: {
          messageId: $mid,
          role: "user",
          parts: [{ kind: "text", text: $query }]
        }
      }
    }')

  local response
  response=$(retry_curl -X POST "$A2A_URL" \
    -H "Content-Type: application/json" \
    -d "$payload") || { echo ""; return 1; }

  echo "$response" | jq -r '
    .result.artifacts[0].parts[0].text //
    .result.message.parts[0].text //
    .result.parts[0].text //
    empty' 2>/dev/null || echo ""
}

# --- Fetch Zendesk tickets ---
fetch_zendesk_tickets() {
  local org="$1"
  local days="$2"
  local since_date
  since_date=$(date -v-${days}d +%Y-%m-%d 2>/dev/null || date -d "${days} days ago" +%Y-%m-%d 2>/dev/null || echo "")

  if [[ -z "$ZD_TOKEN" || -z "$ZD_EMAIL" || "$ZD_EMAIL" == "null" ]]; then
    echo ""
    return 1
  fi

  local all_results="[]"
  local url="https://${ZD_SUBDOMAIN}.zendesk.com/api/v2/search.json?per_page=100&query=type:ticket+organization:${org}+created>${since_date}"

  while [[ -n "$url" && "$url" != "null" ]]; do
    local response
    response=$(retry_curl -u "${ZD_EMAIL}/token:${ZD_TOKEN}" "$url") || { echo ""; return 1; }
    all_results=$(jq -s '.[0] + (.[1].results // [])' <(echo "$all_results") <(echo "$response"))
    url=$(echo "$response" | jq -r '.next_page // empty' 2>/dev/null || echo "")
  done

  # Wrap results back in expected format
  jq -n --argjson results "$all_results" '{results: $results, count: ($results | length)}'
}

# --- Process each customer ---
all_briefs=""

# Authenticate Tableau once
TABLEAU_AVAILABLE=false
if [[ "$DRY_RUN" != "true" ]]; then
  tableau_auth && TABLEAU_AVAILABLE=true
fi

CUSTOMERS_PROCESSED=0

for i in $(seq 0 $((CUSTOMER_COUNT - 1))); do
  name=$(jq -r ".customers[$i].name" "$CONFIG_PATH")
  org_id=$(jq -r ".customers[$i].org_id" "$CONFIG_PATH")
  tableau_name=$(jq -r ".customers[$i].tableau_name // .customers[$i].name" "$CONFIG_PATH")
  zendesk_org=$(jq -r ".customers[$i].zendesk_org // empty" "$CONFIG_PATH")

  # Filter by customer name if specified
  if [[ -n "$CUSTOMER_FILTER" && "$name" != "$CUSTOMER_FILTER" ]]; then
    continue
  fi

  echo "━━━ Processing: $name ($org_id) ━━━" >&2

  # Tableau token re-auth: every 5 customers
  if [[ "$DRY_RUN" != "true" && "$TABLEAU_AVAILABLE" == "true" && $CUSTOMERS_PROCESSED -gt 0 && $((CUSTOMERS_PROCESSED % 5)) -eq 0 ]]; then
    echo "  🔄 Re-authenticating Tableau (every 5 customers)..." >&2
    tableau_auth || TABLEAU_AVAILABLE=false
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  🧪 Dry run — skipping data fetch for $name" >&2
    cat <<EOF

════════════════════════════════════════════════════════════════
  EXECUTIVE BRIEF: $name
  Generated: $(date +"%Y-%m-%d %H:%M %Z") (DRY RUN)
  Period: Last $DAYS days
════════════════════════════════════════════════════════════════

  [DRY RUN] No data fetched. Would query:
  - Tableau revenue for "$tableau_name"
  - Zendesk tickets for "$zendesk_org" (last $DAYS days)
  - Billing A2A for org $org_id (balance, MRC, credit)

  Sections: $SECTIONS

EOF
    continue
  fi

  # --- Collect data ---
  revenue_data=""
  revenue_source=""

  # 1. Try Tableau first
  if [[ "$TABLEAU_AVAILABLE" == "true" ]]; then
    echo "  📈 Fetching revenue from Tableau..." >&2
    revenue_data=$(fetch_tableau_revenue "$tableau_name" 2>/dev/null || echo "")
    if [[ -n "$revenue_data" ]]; then
      revenue_source="Tableau"
      echo "  ✅ Tableau revenue data received" >&2
    fi
  fi

  # 2. Fallback to A2A for revenue
  if [[ -z "$revenue_data" ]]; then
    echo "  📈 Fetching revenue from Billing A2A (fallback)..." >&2
    revenue_data=$(a2a_query "For org $org_id, provide monthly revenue for the last 6 months broken down by product/service. Include totals, MoM changes, and service-level breakdown. Return as JSON.")
    revenue_source="Billing A2A"
    if [[ -n "$revenue_data" ]]; then
      echo "  ✅ A2A revenue data received" >&2
    else
      echo "  ⚠️  No revenue data available" >&2
    fi
  fi

  # 3. Zendesk tickets
  ticket_data=""
  if [[ -n "$zendesk_org" && "$zendesk_org" != "null" ]]; then
    echo "  🎫 Fetching Zendesk tickets (last $DAYS days)..." >&2
    ticket_data=$(fetch_zendesk_tickets "$zendesk_org" "$DAYS" 2>/dev/null || echo "")
    if [[ -n "$ticket_data" ]]; then
      echo "  ✅ Zendesk ticket data received" >&2
    else
      echo "  ⚠️  No Zendesk data available" >&2
    fi
  fi

  # 4. Billing A2A — split into 3 simple queries
  echo "  💰 Fetching billing data from A2A (3 queries)..." >&2

  # Query 1: Balance, credit limit, payment method
  echo "    Q1: balance/credit/payment..." >&2
  q1_text=$(a2a_query "What is the current balance, credit limit, and payment method for org ${org_id}?")
  current_balance=$(extract_number "$q1_text" "balance")
  credit_limit=$(extract_number "$q1_text" "credit.limit")
  payment_method=$(echo "$q1_text" | grep -ioE '(credit.card|wire|ach|paypal|invoice|prepaid)' | head -1 || echo "unknown")

  # Query 2: Usage, MRC, daily run rate
  echo "    Q2: usage/MRC/run rate..." >&2
  q2_text=$(a2a_query "What is the current month usage, MRC, and daily run rate for org ${org_id}?")
  current_month_usage=$(extract_number "$q2_text" "usage|total.usage")
  next_month_mrc=$(extract_number "$q2_text" "mrc|monthly.recurring|recurring.charge")
  daily_run_rate=$(extract_number "$q2_text" "daily|run.rate")

  # Query 3: Auto-recharge, contract end
  echo "    Q3: auto-recharge/contract..." >&2
  q3_text=$(a2a_query "Does org ${org_id} have auto-recharge enabled? What is the contract end date?")
  has_autorecharge=$(extract_bool "$q3_text" "auto.?recharge")
  contract_end=$(echo "$q3_text" | grep -ioE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || echo "")

  # Assemble billing_data as JSON
  billing_data=$(jq -n \
    --arg balance "$current_balance" \
    --arg credit_limit "$credit_limit" \
    --arg payment_method "$payment_method" \
    --arg usage "$current_month_usage" \
    --arg mrc "$next_month_mrc" \
    --arg daily_rate "$daily_run_rate" \
    --arg autorecharge "$has_autorecharge" \
    --arg contract_end "$contract_end" \
    '{
      current_balance: $balance,
      credit_limit: $credit_limit,
      payment_method: $payment_method,
      current_month_usage: $usage,
      next_month_mrc: $mrc,
      daily_run_rate: $daily_rate,
      has_autorecharge: ($autorecharge == "true"),
      contract_end_date: $contract_end
    }')
  echo "  ✅ Billing data received" >&2

  # 5. Build data JSON for narrative generator
  data_json=$(jq -n \
    --arg name "$name" \
    --arg org_id "$org_id" \
    --arg days "$DAYS" \
    --arg sections "$SECTIONS" \
    --arg revenue_source "$revenue_source" \
    --arg revenue_data "$revenue_data" \
    --arg ticket_data "$ticket_data" \
    --arg billing_data "$billing_data" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      customer: $name,
      org_id: $org_id,
      period_days: ($days | tonumber),
      sections: ($sections | split(",")),
      timestamp: $timestamp,
      data: {
        revenue: { source: $revenue_source, raw: $revenue_data },
        tickets: { raw: $ticket_data },
        billing: { raw: $billing_data }
      }
    }')

  # 6. Generate narrative
  echo "  📝 Generating narrative..." >&2
  brief=$(echo "$data_json" | bash "$SCRIPT_DIR/generate-narrative.sh")

  all_briefs="${all_briefs}${brief}\n"
  echo "  ✅ Brief generated for $name" >&2
  CUSTOMERS_PROCESSED=$((CUSTOMERS_PROCESSED + 1))
done

# --- Output ---
output_text=$(echo -e "$all_briefs")

if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$output_text" > "$OUTPUT_FILE"
  echo "📁 Brief saved to $OUTPUT_FILE" >&2
fi

echo "$output_text"

# --- Post to Slack ---
if [[ -n "$SLACK_CHANNEL" && -n "${SLACK_BOT_TOKEN:-}" && "$DRY_RUN" != "true" ]]; then
  echo "📨 Posting brief to Slack channel $SLACK_CHANNEL..." >&2
  slack_response=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg channel "$SLACK_CHANNEL" --arg text "$output_text" \
      '{channel: $channel, text: $text, unfurl_links: false}')")
  if echo "$slack_response" | jq -e '.ok == true' &>/dev/null; then
    echo "  ✅ Brief posted to Slack" >&2
  else
    echo "  ⚠️  Slack post failed: $(echo "$slack_response" | jq -r '.error // "unknown"')" >&2
  fi
elif [[ -n "$SLACK_CHANNEL" && -z "${SLACK_BOT_TOKEN:-}" ]]; then
  echo "⚠️  Slack channel configured but SLACK_BOT_TOKEN not set — skipping Slack post" >&2
fi

echo "✅ Executive Brief completed for $(echo "$all_briefs" | grep -c '═══.*EXECUTIVE BRIEF' || echo 0) customer(s)" >&2
