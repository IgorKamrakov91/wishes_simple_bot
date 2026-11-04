# Wishes Simple Bot

## Description
A Telegram bot for managing personal wishlists and sharing them with friends.

## Demo & Features
https://t.me/PodarkiNeOtdarkiBot

- Create and manage multiple wishlists.
- Add items to your wishlists.
- Share wishlists with other Telegram users, granting them viewing access.
- Intuitive conversational interface.

## Getting Started

### Prerequisites
- Ruby (version specified in `.ruby-version`)
- Rails (version specified in `Gemfile.lock`)
- PostgreSQL
- Telegram Bot Token

### Installation

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/IgorKamrakov91/wishes_simple_bot.git
    cd wishes_simple_bot
    ```

2.  **Install dependencies:**
    ```bash
    bundle install
    ```

3.  **Database setup:**
    ```bash
    rails db:create
    rails db:migrate
    ```

4.  **Environment Variables:**
    Copy `.env.example` to `.env` and replace the placeholder values, or set the
    same variables directly in your shell/deployment environment:
    ```bash
    cp .env.example .env
    ```

    Required values include `TELEGRAM_BOT_TOKEN` and `DATABASE_URL`. Optional
    values such as `BOT_USERNAME`, `RAILS_MASTER_KEY`, and Puma runtime settings
    are documented in `.env.example`.

5.  **Run the application:**
    ```bash
    rails server
    ```
    This will start the Rails application. You'll also need to set up a webhook for your Telegram bot.

### Setting up Telegram Webhook
Your bot needs to know where to send updates. Register the webhook with the rake task:
```bash
TELEGRAM_WEBHOOK_URL=https://YOUR_APP_URL/telegram/webhook bin/rails telegram:set_webhook
```
The task also sets `allowed_updates` (`message`, `callback_query`, `inline_query`) and a `secret_token`.
Telegram sends that token in the `X-Telegram-Bot-Api-Secret-Token` header, and the app rejects
updates without it (401), so forged requests can't act on behalf of other users. The secret is derived
from `TELEGRAM_BOT_TOKEN`; set `TELEGRAM_WEBHOOK_SECRET` to use your own value instead.

Re-run the task whenever the URL, the bot token or the secret changes. In production Kamal's
`.kamal/hooks/post-deploy` runs it after every `kamal deploy`, `redeploy` and `rollback`, whether
the deploy is manual or from GitHub Actions.

`getWebhookInfo` shows the URL and `allowed_updates`, but not whether a secret is set. The real check
is that the bot answers: if every update gets 401 (`last_error_message` in `getWebhookInfo`, 401s in
the app log), the webhook was registered without the current secret.

## Deployment
Production runs on a single VPS and is deployed with [Kamal](https://kamal-deploy.org) (`config/deploy.yml`):
- kamal-proxy terminates TLS with a Let's Encrypt certificate;
- Postgres 17 runs as a Kamal accessory on the same server, bound to `127.0.0.1`;
- the image is pushed through a local registry over SSH, so no external registry is needed.

Secrets are read by `.kamal/secrets` from a gitignored `.env.production` in the project root:
```
TELEGRAM_BOT_TOKEN=...
BOT_USERNAME=...
POSTGRES_PASSWORD=...   # URL-safe, e.g. `openssl rand -hex 24`
```
`RAILS_MASTER_KEY` comes from `config/master.key`.

Deploys run automatically from GitHub Actions (`.github/workflows/deploy.yml`) after CI passes on `main`; they can also be started manually from the Actions tab. The workflow needs these repository secrets: `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`, `RAILS_MASTER_KEY`, `TELEGRAM_BOT_TOKEN`, `BOT_USERNAME`, `POSTGRES_PASSWORD`.

To deploy from your machine instead (Docker must be running locally):
```bash
bin/kamal deploy
```
Useful aliases: `bin/kamal logs`, `bin/kamal console`, `bin/kamal shell`.

### If the bot stops answering after a deploy
The new version rejects updates until the webhook is registered with its secret. The post-deploy hook
does that; if the hook failed (the deploy itself still counts as done), register it by hand:
```bash
bin/kamal app exec --reuse "bin/rails telegram:set_webhook"
```
Then send the bot a message to check it answers. Telegram retries rejected updates for a limited,
unspecified time, so updates sent while the webhook was broken may be lost.

Rolling back to a version from before the secret check is not a safe fix: that image has no
`telegram:set_webhook` task, so the post-deploy hook fails, and the old app accepts updates without
checking the secret, i.e. forged updates work again. Treat such a rollback as a short emergency measure
and deploy a fixed version as soon as possible.

## Usage
Interact with the bot directly on Telegram.
- Start a chat with your bot.
- Use commands like `/start` to begin.
- Follow the bot's conversational prompts to create wishlists, add items, and share.

## Running Tests
```bash
bundle exec rails test
```
