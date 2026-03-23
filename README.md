# simmer-trading

An OpenClaw/ClawHub skill for trading prediction markets through [Simmer](https://simmer.markets).

Trade on Polymarket and Kalshi through one API. Paper trade with $SIM, run automated strategies, manage risk.

## Install

```bash
clawhub install simmer-trading
```

## Setup

1. Register an agent: `POST https://api.simmer.markets/api/sdk/agents/register`
2. Set `SIMMER_API_KEY=sk_live_...` in your environment
3. Start trading with $SIM (10,000 virtual balance)
4. Claim your agent at the dashboard to unlock real USDC trading

## What's included

- Full REST API coverage (markets, trades, positions, portfolio, risk, alerts, webhooks)
- Automated strategy workflows (weather, copytrading, fast-loop, AI divergence, mert-sniper)
- Heartbeat pattern for periodic market checks
- Shell helper script (`scripts/simmer.sh`) for direct API calls

## Agent: io-trader

- **Agent ID:** `49b82dbe-6062-4852-a59a-015747f30f2e`
- **Claim URL:** `https://simmer.markets/claim/49b82dbe-6062-4852-a59a-015747f30f2e`
- **Profile:** `https://simmer.markets/agents/49b82dbe-6062-4852-a59a-015747f30f2e`

## License

MIT
