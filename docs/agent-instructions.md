# Executive Brief — Agent Instructions

## Purpose
Generate executive account briefs on a schedule or on-demand via OpenClaw.

## Cron Setup

### Weekly Account Reviews (Recommended)
Schedule: `0 8 * * 1` (Every Monday at 8:00 AM)

```
cd ~/clawd/skills/executive-brief && source .env && bash scripts/executive-brief.sh --output output/weekly-$(date +%Y-%m-%d).txt
```

### Monthly Deep Dives
Schedule: `0 9 1 * *` (1st of each month at 9:00 AM)

```
cd ~/clawd/skills/executive-brief && source .env && bash scripts/executive-brief.sh --days 180 --output output/monthly-$(date +%Y-%m-%d).txt
```

### Single Customer On-Demand
No schedule — run manually or trigger via OpenClaw:

```
cd ~/clawd/skills/executive-brief && source .env && bash scripts/executive-brief.sh --customer "Acme Corp" --days 60
```

## What It Does
1. Reads customer list from `config/config.json`
2. For each customer, fetches revenue (Tableau → A2A fallback), support (Zendesk), and billing (A2A) data
3. Generates a formatted brief with TLDR, revenue trends, support overview, risks, opportunities, and action items
4. Outputs to stdout and optionally saves to file

## Required Environment
- `TABLEAU_PAT_SECRET` — Tableau Personal Access Token secret
- `ZENDESK_API_TOKEN` — Zendesk API token
- `CONFIG_PATH` — Path to config JSON (defaults to `./config/config.json`)
- Network access to Tableau, Zendesk, and billing A2A agent

## Troubleshooting
- **Tableau auth fails**: Check PAT name matches config, secret is correct, PAT hasn't expired
- **No revenue data**: Both Tableau and A2A failed — check network/VPN
- **Zendesk errors**: Verify email and API token, check subdomain
- **Parse errors**: Data source may return unexpected format — check raw output with `--dry-run`
