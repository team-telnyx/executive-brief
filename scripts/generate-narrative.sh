#!/usr/bin/env bash
# Generate Narrative — takes JSON data on stdin, outputs formatted executive brief
# Can be extended to call an LLM for richer narratives
set -euo pipefail

# Read JSON from stdin
DATA=$(cat)

CUSTOMER=$(echo "$DATA" | jq -r '.customer')
ORG_ID=$(echo "$DATA" | jq -r '.org_id')
PERIOD=$(echo "$DATA" | jq -r '.period_days')
TIMESTAMP=$(echo "$DATA" | jq -r '.timestamp')
SECTIONS=$(echo "$DATA" | jq -r '.sections | join(",")')

REVENUE_RAW=$(echo "$DATA" | jq -r '.data.revenue.raw // ""')
REVENUE_SOURCE=$(echo "$DATA" | jq -r '.data.revenue.source // "N/A"')
TICKET_RAW=$(echo "$DATA" | jq -r '.data.tickets.raw // ""')
BILLING_RAW=$(echo "$DATA" | jq -r '.data.billing.raw // ""')

# --- Parse billing data ---
BALANCE=$(echo "$BILLING_RAW" | jq -r '.current_balance // "N/A"' 2>/dev/null || echo "N/A")
CREDIT_LIMIT=$(echo "$BILLING_RAW" | jq -r '.credit_limit // "N/A"' 2>/dev/null || echo "N/A")
MRC=$(echo "$BILLING_RAW" | jq -r '.next_month_mrc // "N/A"' 2>/dev/null || echo "N/A")
USAGE=$(echo "$BILLING_RAW" | jq -r '.current_month_usage // "N/A"' 2>/dev/null || echo "N/A")
AUTORECHARGE=$(echo "$BILLING_RAW" | jq -r '.has_autorecharge_enabled // "N/A"' 2>/dev/null || echo "N/A")
CONTRACT_END=$(echo "$BILLING_RAW" | jq -r '.contract_end_date // "N/A"' 2>/dev/null || echo "N/A")

# --- Parse ticket data ---
TICKET_COUNT=$(echo "$TICKET_RAW" | jq -r '.count // 0' 2>/dev/null || echo "0")

# --- Helper: check if section is enabled ---
has_section() {
  echo "$SECTIONS" | grep -qi "$1"
}

# --- Generate brief ---
cat <<HEADER

════════════════════════════════════════════════════════════════
  EXECUTIVE BRIEF: $CUSTOMER
  Generated: $(date -d "$TIMESTAMP" +"%B %d, %Y at %H:%M %Z" 2>/dev/null || date +"%B %d, %Y at %H:%M %Z")
  Period: Last $PERIOD days | Org: $ORG_ID
  Data Sources: Revenue ($REVENUE_SOURCE), Support (Zendesk), Billing (A2A)
════════════════════════════════════════════════════════════════
HEADER

# --- TLDR ---
if has_section "tldr"; then
  cat <<TLDR

┌─────────────────────────────────────────────────────────────┐
│  📋 TLDR                                                     │
└─────────────────────────────────────────────────────────────┘

  Account balance: $BALANCE | Credit limit: $CREDIT_LIMIT
  Current month usage: $USAGE | MRC: $MRC
  Support tickets (${PERIOD}d): $TICKET_COUNT
  Auto-recharge: $AUTORECHARGE | Contract ends: $CONTRACT_END

TLDR
fi

# --- Revenue Trends ---
if has_section "revenue"; then
  cat <<REVENUE

┌─────────────────────────────────────────────────────────────┐
│  📈 REVENUE TRENDS                                           │
└─────────────────────────────────────────────────────────────┘

  Source: $REVENUE_SOURCE
  Period: Last $PERIOD days

REVENUE

  if [[ -n "$REVENUE_RAW" && "$REVENUE_RAW" != "null" && "$REVENUE_RAW" != "" ]]; then
    # Try to format revenue data
    echo "$REVENUE_RAW" | jq -r '
      if type == "object" then
        to_entries[] | "  \(.key): $\(.value)"
      elif type == "array" then
        .[] | if type == "object" then
          to_entries | map("  \(.key): \(.value)") | join("\n")
        else
          "  \(.)"
        end
      else
        "  \(.)"
      end
    ' 2>/dev/null || echo "  $REVENUE_RAW"
  else
    echo "  ⚠️  No revenue data available"
  fi
  echo ""
fi

# --- Support Overview ---
if has_section "support"; then
  cat <<SUPPORT

┌─────────────────────────────────────────────────────────────┐
│  🎫 SUPPORT OVERVIEW                                         │
└─────────────────────────────────────────────────────────────┘

  Tickets in last $PERIOD days: $TICKET_COUNT

SUPPORT

  if [[ "$TICKET_COUNT" -gt 0 ]] 2>/dev/null; then
    # Try to extract ticket categories
    echo "$TICKET_RAW" | jq -r '
      .results // [] | group_by(.status) | .[] |
      "  Status: \(.[0].status // "unknown") — \(length) ticket(s)"
    ' 2>/dev/null || echo "  (Detailed breakdown requires ticket parsing)"

    # Fault breakdown placeholder
    echo ""
    echo "  Fault Breakdown:"
    echo "  ├── Telnyx:      (see detailed ticket analysis)"
    echo "  ├── Carrier:     (see detailed ticket analysis)"
    echo "  ├── Customer:    (see detailed ticket analysis)"
    echo "  └── Regulatory:  (see detailed ticket analysis)"
  else
    echo "  ✅ No support tickets in this period"
  fi
  echo ""
fi

# --- Key Risks ---
if has_section "risks"; then
  cat <<RISKS

┌─────────────────────────────────────────────────────────────┐
│  ⚠️  KEY RISKS                                               │
└─────────────────────────────────────────────────────────────┘

RISKS

  risk_count=0

  # Check credit utilization
  if [[ "$BALANCE" != "N/A" && "$CREDIT_LIMIT" != "N/A" ]]; then
    utilization=$(echo "$BALANCE $CREDIT_LIMIT" | awk '{
      if ($2 != 0) { pct = ($1 / $2) * 100; if (pct < 0) pct = -pct; printf "%.0f", pct }
      else print "N/A"
    }' 2>/dev/null || echo "N/A")
    if [[ "$utilization" != "N/A" && "$utilization" -gt 80 ]] 2>/dev/null; then
      echo "  🔴 Credit utilization at ${utilization}% — approaching limit"
      risk_count=$((risk_count + 1))
    fi
  fi

  # Check auto-recharge
  if [[ "$AUTORECHARGE" == "false" ]]; then
    echo "  🟡 Auto-recharge disabled — risk of service disruption"
    risk_count=$((risk_count + 1))
  fi

  # Check contract end
  if [[ "$CONTRACT_END" != "N/A" && "$CONTRACT_END" != "null" ]]; then
    echo "  📅 Contract end date: $CONTRACT_END — review renewal timeline"
    risk_count=$((risk_count + 1))
  fi

  # Check ticket volume
  if [[ "$TICKET_COUNT" -gt 10 ]] 2>/dev/null; then
    echo "  🟠 High ticket volume ($TICKET_COUNT tickets in ${PERIOD}d) — investigate patterns"
    risk_count=$((risk_count + 1))
  fi

  if [[ $risk_count -eq 0 ]]; then
    echo "  ✅ No significant risks identified"
  fi
  echo ""
fi

# --- Opportunities ---
if has_section "opportunities"; then
  cat <<OPPS

┌─────────────────────────────────────────────────────────────┐
│  💡 OPPORTUNITIES                                            │
└─────────────────────────────────────────────────────────────┘

  Based on account data:
  • Review product mix for upsell potential
  • Evaluate usage trends for volume discount eligibility
  • Check if customer is using all available product lines
  • Consider contract renewal with favorable terms if approaching end date

OPPS
fi

# --- Action Items ---
if has_section "actions"; then
  cat <<ACTIONS

┌─────────────────────────────────────────────────────────────┐
│  ✅ ACTION ITEMS                                             │
└─────────────────────────────────────────────────────────────┘

  Recommended next steps:
  □ Review revenue trends and identify growth/decline drivers
  □ Address any open support tickets with recurring patterns
  □ Confirm credit limit and auto-recharge settings are appropriate
  □ Schedule QBR if not done in last 90 days
  □ Update Salesforce with latest account notes

ACTIONS
fi

cat <<FOOTER
════════════════════════════════════════════════════════════════
  End of Brief — $CUSTOMER
════════════════════════════════════════════════════════════════
FOOTER
