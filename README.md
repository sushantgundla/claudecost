# claudecost

See what Claude Code is costing you. One bash script, zero dependencies.

```bash
[curl -O https://raw.githubusercontent.com/<your-username>/claudecost/main/claudecost.sh](https://raw.githubusercontent.com/sushantgundla/claudecost/refs/heads/main/claudecost.sh)
chmod +x claudecost.sh
./claudecost.sh
```

```
╔══════════════════════════════════════════════════════════════════╗
║             ⚡ Claude Code Usage Dashboard ⚡                      ║
║            pricing: LiteLLM (19 models)                          ║
╚══════════════════════════════════════════════════════════════════╝

  ┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐
  │ Total tokens     │ Est. API cost    │ Active days      │ Cache hit rate   │
  │ 372.0M           │ $246.12          │ 30               │ 90.8%            │
  ├──────────────────┼──────────────────┼──────────────────┼──────────────────┤
  │ Avg cost/day     │ Avg tokens/day   │ Peak day cost    │ Peak day         │
  │ $8.20            │ 12.4M            │ $37.80           │ Feb 17           │
  └──────────────────┴──────────────────┴──────────────────┴──────────────────┘

  📊 Monthly Cost (USD)

  Jan 2026 │ ████                             $15.65
  Feb 2026 │ ████████████████████████████████████████ $170.76
  Mar 2026 │ ██████████████ $59.71
```

## Usage

```bash
./claudecost.sh                          # daily view (default)
./claudecost.sh --freq monthly           # monthly chart
./claudecost.sh --freq weekly --days 30  # weekly, last 30 days
./claudecost.sh --project my-app         # filter by project
./claudecost.sh --month 2026-02          # specific month
./claudecost.sh --offline                # no internet? hardcoded pricing
```

## How It Works

Reads `~/.claude/projects/**/*.jsonl` locally, deduplicates streaming chunks using `messageId:requestId` (same as [ccusage](https://github.com/ryoppippi/ccusage)), fetches live pricing from [LiteLLM](https://github.com/BerriAI/litellm), and renders a dashboard.

Tested side-by-side with `npx ccusage` — numbers match within pennies.

## Requirements

bash + awk + curl. All ship with macOS. No Python, no Node.js, nothing to install.

## License

MIT
