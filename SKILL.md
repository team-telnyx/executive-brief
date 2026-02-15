# SKILL: Executive Brief

## Name
executive-brief

## Description
Generates C-suite ready account narratives for any customer. Pulls data from Tableau (revenue), Zendesk (support), and Billing A2A (financials) to produce a comprehensive executive brief with TLDR, revenue trends, support overview, key risks, opportunities, and action items.

## Schedule
On-demand (or cron for periodic account reviews)

Example cron: `0 8 * * 1` (Every Monday at 8:00 AM — weekly account reviews)

## Commands
```bash
# Generate brief for all customers in config
bash scripts/executive-brief.sh

# Generate brief for a specific customer
bash scripts/executive-brief.sh --customer "Acme Corp"

# Adjust lookback period (default: 90 days)
bash scripts/executive-brief.sh --days 30

# Save to file
bash scripts/executive-brief.sh --output output/acme-brief.txt

# Only specific sections
bash scripts/executive-brief.sh --sections "tldr,revenue,risks"

# Dry run — validate config without making external calls
bash scripts/executive-brief.sh --dry-run

# Combine flags
bash scripts/executive-brief.sh --customer "Acme Corp" --days 60 --output output/acme-q4.txt
```

## Flags
| Flag | Description |
|------|-------------|
| `--customer <name>` | Generate brief for a single customer (must match config name exactly) |
| `--days <n>` | Lookback period in days (default: from config, usually 90) |
| `--output <file>` | Save brief to file (also prints to stdout) |
| `--dry-run` | Validate config and show what would be queried, no external calls |
| `--sections <list>` | Comma-separated sections: tldr,revenue,support,risks,opportunities,actions |

## Environment Variables
| Variable | Required | Description |
|----------|----------|-------------|
| `TABLEAU_PAT_SECRET` | Yes* | Tableau Personal Access Token secret (each CSM needs their own) |
| `ZENDESK_API_TOKEN` | Yes* | Zendesk API token (each CSM needs their own) |
| `SLACK_BOT_TOKEN` | No | Slack bot token for posting briefs to channels |
| `CONFIG_PATH` | No | Path to config JSON (default: `./config/config.json`) |
| `DRY_RUN` | No | Set `true` to enable dry-run mode |

*Tableau is primary for revenue; falls back to Billing A2A if unavailable. Zendesk required for support data only.

## Data Sources (Priority Order)
1. **Tableau** — Primary for revenue trends (REST API, PAT auth)
2. **Billing A2A** — Fallback for revenue, primary for balance/credit/MRC
3. **Zendesk** — Support ticket data

## Built-in Resilience
- **Config validation** runs at startup — catches missing/invalid settings early
- **Retry logic** — 3 attempts with exponential backoff on transient failures
- **Curl timeouts** — 10s connect, 30s max per request
- **Graceful fallback** — Tableau failure falls back to A2A for revenue data
- **Dry-run mode** — Validate everything without making external calls

## Output Sections
1. **TLDR** — 2-3 sentence summary of account health
2. **Revenue Trends** — MoM changes, service-level breakdown
3. **Support Overview** — Ticket volume, categories, fault breakdown
4. **Key Risks** — Revenue drops, recurring issues, contract gaps, credit concerns
5. **Opportunities** — Upsell potential, expansion areas
6. **Action Items** — Recommended next steps

## Dependencies
- `bash`, `curl`, `jq`, `python3` (for URL encoding)
- Network access to Tableau server, Zendesk API, and billing A2A agent

## Author
team-telnyx / CSM team

## Tags
executive, brief, account-review, revenue, support, tableau, zendesk, a2a
