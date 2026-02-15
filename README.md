# Executive Brief (Account Narrative Generator)

Generate C-suite ready account narratives for any customer. Pulls data from multiple sources and produces a comprehensive brief covering revenue trends, support health, risks, opportunities, and action items.

## How It Works

For each customer in your config, the tool:

1. **Authenticates with Tableau** using your Personal Access Token (PAT)
2. **Fetches revenue data** from Tableau (falls back to Billing A2A if unavailable)
3. **Pulls support tickets** from Zendesk for the configured lookback period
4. **Queries Billing A2A** for balance, credit limit, MRC, and account status
5. **Generates a formatted brief** with configurable sections

## Brief Sections

| Section | What It Covers |
|---------|---------------|
| **TLDR** | 2-3 sentence summary of account health |
| **Revenue Trends** | Last 3-6 months, MoM changes, service-level breakdown |
| **Support Overview** | Ticket volume, categories, fault breakdown (Telnyx/carrier/customer/regulatory) |
| **Key Risks** | Revenue drops, recurring issues, contract gaps, credit concerns |
| **Opportunities** | Upsell potential, new products, expansion areas |
| **Action Items** | Recommended next steps for the account team |

## Quick Start (10 minutes)

### 1. Clone & Configure

```bash
git clone https://github.com/team-telnyx/telnyx-clawdbot-skills.git
cd telnyx-clawdbot-skills/skills/executive-brief

# Create your config from the template
cp config/example-config.json config/config.json
# Edit config/config.json with your customer data
```

### 2. Set Environment Variables

```bash
cp .env.example .env
# Edit .env:
#   TABLEAU_PAT_SECRET=your-tableau-pat-secret
#   ZENDESK_API_TOKEN=your-zendesk-api-token
#   SLACK_BOT_TOKEN=xoxb-your-token  (optional)
```

**Getting a Tableau PAT:**
1. Log into Tableau Server → My Account Settings → Personal Access Tokens
2. Create a new token, note the name and secret
3. Set `pat_name` in config and `TABLEAU_PAT_SECRET` in .env

**Getting a Zendesk API Token:**
1. Zendesk Admin → Apps & Integrations → APIs → Zendesk API
2. Add API Token, copy it
3. Set `ZENDESK_API_TOKEN` in .env

### 3. Run

```bash
# Source environment
source .env

# Brief for all customers
bash scripts/executive-brief.sh

# Single customer
bash scripts/executive-brief.sh --customer "Acme Corp"

# Dry run (validate config, no external calls)
bash scripts/executive-brief.sh --dry-run

# Save to file
bash scripts/executive-brief.sh --customer "Acme Corp" --output output/acme-brief.txt

# Custom lookback and sections
bash scripts/executive-brief.sh --days 30 --sections "tldr,revenue,risks"
```

### 4. Set Up as OpenClaw Cron Job

See `docs/agent-instructions.md` for automated scheduling.

## Example Output

```
════════════════════════════════════════════════════════════════
  EXECUTIVE BRIEF: Acme Corp
  Generated: February 15, 2026 at 08:00 CST
  Period: Last 90 days | Org: abc-123-def-456
  Data Sources: Revenue (Tableau), Support (Zendesk), Billing (A2A)
════════════════════════════════════════════════════════════════

┌─────────────────────────────────────────────────────────────┐
│  📋 TLDR                                                     │
└─────────────────────────────────────────────────────────────┘

  Account balance: -$2,340.50 | Credit limit: $10,000
  Current month usage: $3,200 | MRC: $1,500
  Support tickets (90d): 12
  Auto-recharge: true | Contract ends: 2026-06-30

┌─────────────────────────────────────────────────────────────┐
│  📈 REVENUE TRENDS                                           │
└─────────────────────────────────────────────────────────────┘

  Source: Tableau
  ...

┌─────────────────────────────────────────────────────────────┐
│  ⚠️  KEY RISKS                                               │
└─────────────────────────────────────────────────────────────┘

  📅 Contract end date: 2026-06-30 — review renewal timeline
  🟠 High ticket volume (12 tickets in 90d) — investigate patterns

════════════════════════════════════════════════════════════════
  End of Brief — Acme Corp
════════════════════════════════════════════════════════════════
```

## Data Sources

| Source | Purpose | Auth |
|--------|---------|------|
| **Tableau** (primary) | Revenue trends, MoM changes | PAT (each CSM needs their own) |
| **Billing A2A** (fallback) | Revenue fallback, balance, credit, MRC | None (internal network) |
| **Zendesk** | Support tickets, categories, fault analysis | API token (each CSM needs their own) |

## Config File Format

See `config/example-config.json`. Key sections:

| Section | Description |
|---------|-------------|
| `customers` | Array of `{name, org_id, tableau_name, zendesk_org}` |
| `tableau` | Server, site, PAT name, view ID |
| `zendesk` | Subdomain, email |
| `a2a` | Billing agent URL |
| `output` | Format, sections, default lookback days |
| `slack` | Channel for posting briefs |

## Features

- **Multi-source data**: Tableau → A2A fallback for revenue, Zendesk for support
- **Retry logic**: 3 attempts with exponential backoff on all API calls
- **Timeouts**: 10s connect, 30s max on all HTTP requests
- **Config validation**: Validates JSON structure and required fields at startup
- **Dry-run mode**: Preview without making external calls
- **Flexible output**: Filter by customer, sections, lookback period
- **File output**: Save briefs with `--output` for audit trail

## Requirements

- `bash`, `curl`, `jq`, `python3`
- Network access to Tableau server, Zendesk, and billing A2A agent
- OpenClaw (for automated scheduling)

## Security

- **No secrets in the repo.** All tokens via environment variables.
- **No customer data in the repo.** All customer info via your local config file.
- `config/config.json` and `.env` are gitignored.
