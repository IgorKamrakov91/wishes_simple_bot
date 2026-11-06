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

### Bot profile
`bin/rails telegram:set_profile` sets the description shown before /start, the short description and
the command menu from `bot.profile` in the Russian locale for every user language, and removes the English
variants set earlier.
The post-deploy hook runs it after the webhook; a failure there only prints a warning.

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

## Reservation notifications

When a gift is reserved or released, `Bot::ReservationNotifier` enqueues a `NotificationJob`
(queue `notifications`, Solid Queue, outside the button response) for:
- the list owner, if "Reservations in my lists" is on (default on);
- the list's guests with "Reservations in friends' lists" on (default off), except the person
  who pressed the button.

Texts never name who reserved. Users switch both settings under Main menu → Settings. The job
re-checks the setting (and, for guests, access to the list) right before sending. Deleting a gift or
a list sends no notifications.

To verify delivery after a deploy, use two test accounts: reserve a gift as a guest. `bin/kamal logs`
should show `Enqueued NotificationJob`, then `Performing` / `Performed`, and the owner should get a
message. Enqueue alone does not prove the worker ran: check `SOLID_QUEUE_IN_PUMA` and the queue
database if execution never starts. A Telegram 403 (the recipient blocked the bot) is logged
without retrying; network errors and 429 are retried up to three attempts.

## Reservation reminders

Settings → Reservation reminders offers Off (default), 7, 14 or 30 days. Enabling or changing
the interval schedules the first reminder at noon on the Moscow calendar date that many days
later; repeating the same setting does not postpone it. Successful delivery schedules the next
one at noon on the delivery's Moscow calendar date plus the selected interval. Send delays do
not drift a reminder past the daily scheduler's next eligible run.
Only accessible reservations in other people's lists without `purchased_at` are included.
The digest contains at most five gift names and links to My reservations and Settings.

`ReservationRemindersJob` runs daily at 12:00 **Europe/Moscow** through `config/recurring.yml`.
Deliveries are spread one second apart rather than enqueued as a broadcast burst.
`ReservationReminderJob` sends between 12:00 and 18:00 Moscow time, deferring late jobs to the next
daytime window. Both use the `reminders` queue, which the production wildcard worker handles.
The due time is claimed in the primary database before sending, so overlapping/replayed jobs
cannot send the same attempt twice. Settings and current unpurchased reservations are rechecked
at delivery. `reservation_reminder_last_sent_at` is updated only after a successful API response;
`reservation_reminder_last_attempt_at` records an attempt even if Telegram cannot be reached.

Telegram 400/403/404 responses are not retried. Rate limits use `retry_after` and other Telegram
errors use a short delay, with at most three attempts per queued delivery. An ambiguous network
failure may mean Telegram accepted the message, so it is not retried immediately; the next
normal interval remains scheduled. A process crash after claiming can also skip that interval.
This favors avoiding duplicate reminders over guaranteed delivery of each reminder.

After deployment, verify that Solid Queue's scheduler loaded `reservation_reminders` and that
the worker executes both jobs, then use a test account with an unpurchased accessible booking
and an enabled interval. Confirm a real Telegram message and a populated `last_sent_at`;
an enqueued job alone does not prove delivery. Marking all bookings bought or disabling the
setting must suppress a queued reminder. Do not change real users' due dates for a smoke test.

## Running Tests

```bash
bundle exec rails test
```
