# Wishes Simple Bot

## Description
A Telegram bot for managing personal wishlists and sharing them with friends.

## Features
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
    git clone https://github.com/your-username/wishes_simple_bot.git
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
    Create a `.env` file (or set environment variables directly) with the following:
    ```
    TELEGRAM_BOT_TOKEN=YOUR_TELEGRAM_BOT_TOKEN
    DATABASE_URL=postgres://user:password@host:port/database_name
    RAILS_MASTER_KEY=YOUR_RAILS_MASTER_KEY # If using Rails encrypted credentials
    ```
    *Replace placeholders with your actual values.*

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