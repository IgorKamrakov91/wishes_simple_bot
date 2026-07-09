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
Your bot needs to know where to send updates. You can set the webhook using the Telegram Bot API directly or a tool.
Example using `curl`:
```bash
curl -F "url=YOUR_APP_URL/telegram/webhook" "https://api.telegram.org/botYOUR_TELEGRAM_BOT_TOKEN/setWebhook"
```
Replace `YOUR_APP_URL` with the public URL of your running Rails application and `YOUR_TELEGRAM_BOT_TOKEN` with your bot's token.

## Usage
Interact with the bot directly on Telegram.
- Start a chat with your bot.
- Use commands like `/start` to begin.
- Follow the bot's conversational prompts to create wishlists, add items, and share.

## Running Tests
```bash
bundle exec rails test
```
