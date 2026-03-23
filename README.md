# Simmer Trading

Autonomous prediction market trading via the [Simmer Markets](https://simmer.markets) API. An OpenClaw skill with three built-in strategies: Weather Trader, Copytrading, and AI Divergence.

## Setup

### 1. Get an API key

Register an agent at [simmer.markets](https://simmer.markets) or call the register endpoint:

```bash
curl -X POST https://api.simmer.markets/api/sdk/agents/register \
  -H "Content-Type: application/json" \
  -d '{"name": "my-agent", "description": "My trading agent"}'
```

Save the `api_key` from the response.

### 2. Set environment variables

```bash
export SIMMER_API_KEY="sk_live_..."
```

### 3. Requirements

- `curl` and `jq` must be installed
- All scripts use `set -euo pipefail` for safety
- All strategies default to `DRY_RUN=true` (no real trades until you opt in)

## Strategies

### Weather Trader (`scripts/weather-trader.sh`)

Trades weather prediction markets using NOAA forecast data and Simmer's AI divergence signal.

| Variable | Default | Description |
|----------|---------|-------------|
| `DRY_RUN` | `true` | Set `false` to execute real trades |
| `EDGE_THRESHOLD` | `0.10` | Minimum edge (10%) to trigger a trade |
| `TRADE_AMOUNT` | `10` | USD per trade |
| `VENUE` | `sim` | `sim` for paper trading, `polymarket` for real |
| `MAX_TRADES` | `5` | Max trades per run |

### Copytrading (`scripts/copytrading.sh`)

Mirrors positions from high-performing whale wallets using Simmer's copytrading endpoint.

| Variable | Default | Description |
|----------|---------|-------------|
| `DRY_RUN` | `true` | Set `false` to execute real trades |
| `COPY_WALLETS` | (required) | Comma-separated wallet addresses to follow |
| `MAX_USD_PER_POSITION` | `50` | Max USD per position |
| `TOP_N` | `10` | Number of positions to mirror |
| `BUY_ONLY` | `true` | Only buy, don't sell other strategies' positions |
| `DETECT_WHALE_EXITS` | `true` | Sell when whales exit their positions |
| `VENUE` | `sim` | `sim` or `polymarket` |

### AI Divergence (`scripts/ai-divergence.sh`)

Finds markets where Simmer's AI price diverges from the market price and trades the gap.

| Variable | Default | Description |
|----------|---------|-------------|
| `DRY_RUN` | `true` | Set `false` to execute real trades |
| `MIN_DIVERGENCE` | `0.05` | Minimum divergence (5%) to trigger a trade |
| `TRADE_AMOUNT` | `10` | USD per trade |
| `VENUE` | `sim` | `sim` or `polymarket` |
| `MAX_TRADES` | `5` | Max trades per run |

## Running

### Manual

```bash
# Paper trade with defaults (dry run)
./scripts/weather-trader.sh

# Live trade on Simmer ($SIM)
DRY_RUN=false ./scripts/ai-divergence.sh

# Copytrade specific wallets
COPY_WALLETS="0xabc...,0xdef..." ./scripts/copytrading.sh
```

### Cron

```bash
# Weather trader every 30 minutes
*/30 * * * * SIMMER_API_KEY=sk_live_... /path/to/scripts/weather-trader.sh >> /tmp/weather-trader.log 2>&1

# Copytrading every 4 hours
0 */4 * * * SIMMER_API_KEY=sk_live_... COPY_WALLETS="0xabc..." /path/to/scripts/copytrading.sh >> /tmp/copytrading.log 2>&1

# AI divergence every 2 hours
0 */2 * * * SIMMER_API_KEY=sk_live_... /path/to/scripts/ai-divergence.sh >> /tmp/ai-divergence.log 2>&1
```

### Helper script

The `scripts/simmer.sh` helper wraps curl with auth and formatting:

```bash
# Check agent status
./scripts/simmer.sh GET /api/sdk/agents/me

# Search markets
./scripts/simmer.sh GET '/api/sdk/markets?q=bitcoin&limit=5'

# Place a trade
./scripts/simmer.sh POST /api/sdk/trade '{"market_id":"abc","side":"yes","amount":10,"venue":"sim"}'
```

## Docs

- [Simmer Markets](https://simmer.markets)
- [API Reference](https://docs.simmer.markets)
- [Full docs for agents](https://docs.simmer.markets/llms-full.txt)
