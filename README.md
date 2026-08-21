# vvsomonitor

24/7 visa slot monitor for india, running on GitHub Actions.

- Polls the public live-slots API every minute, 24/7, from GitHub's cloud runners.
- Stays completely silent by default - no routine status messages.
- When new slots open anywhere, sends a single all-caps alert (with emojis) to all recipients.

## How it works

- `.github/workflows/slot-monitor.yml` - `workflow_dispatch` trigger only; dispatched every minute by an external cron service via the GitHub API.
- `monitor.ps1` - polling engine; runs with `-Once -NoToast`.
- Alert state is persisted between runs via the GitHub Actions cache, so "newly opened" vs "still open" slots are distinguished correctly. Only genuinely NEW openings trigger an alert; still-open or closed slots stay silent.
- No secrets in this repo. The Telegram bot token and recipient chat IDs are provided at runtime via GitHub repository Secrets (`TELEGRAM_TOKEN`, `TELEGRAM_CHAT_IDS`, `API_BASE`).

## Configuration

Set these repository secrets:

| Secret | Value |
| --- | --- |
| `TELEGRAM_TOKEN` | Bot token from @BotFather |
| `TELEGRAM_CHAT_IDS` | JSON array of recipient chat IDs, e.g. `["111111111","222222222"]` |
| `API_BASE` | Base URL of the slot availability API |

Trigger manually anytime with the **Run workflow** button in the Actions tab.

## Note

Runs are triggered every minute by an external cron service (cron-job.org) calling the GitHub workflow dispatch API. GitHub's own scheduler is intentionally not used, as it can be delayed or skipped under load.