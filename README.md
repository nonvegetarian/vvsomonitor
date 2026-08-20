# vvsomonitor

24/7 visa slot monitor for india, running on GitHub Actions.

- Polls the public live-slots API every 5 minutes, 24/7, from GitHub's cloud runners.
- Sends a full per-city / per-visa-type slot status to Telegram after every poll.
- When new slots open anywhere, sends an all-caps alert (with emojis) to Telegram, repeated 5 times.
- If slots remain open on the next poll, normal status text resumes (no repeated spam).

## How it works

- `.github/workflows/slot-monitor.yml` - cron `*/5 * * * *` + manual `workflow_dispatch` trigger.
- `monitor.ps1` - polling engine; runs with `-Once -NoToast`.
- Alert state is persisted between runs via the GitHub Actions cache, so "newly opened" vs "still open" slots are distinguished correctly.
- No secrets in this repo. The Telegram bot token and chat ID are provided at runtime via GitHub repository Secrets (`TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID`).

## Configuration

Set these repository secrets:

| Secret | Value |
| --- | --- |
| `TELEGRAM_TOKEN` | Bot token from @BotFather |
| `TELEGRAM_CHAT_ID` | Your Telegram chat ID |

Trigger manually anytime with the **Run workflow** button in the Actions tab.

## Note

GitHub Actions scheduled runs can occasionally be delayed by a few minutes under load; the typical cadence is every 5 minutes.