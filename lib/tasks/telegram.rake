# The gem is not required by Bundler (its name differs from its entry file)
require "telegram/bot"

namespace :telegram do
  desc "Register the webhook with its secret token (needs TELEGRAM_WEBHOOK_URL)"
  task set_webhook: :environment do
    url = ENV.fetch("TELEGRAM_WEBHOOK_URL")
    bot = Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN"))

    bot.api.set_webhook(
      url: url,
      secret_token: Bot::Webhook.secret,
      allowed_updates: Bot::Webhook::ALLOWED_UPDATES
    )

    info = bot.api.get_webhook_info
    puts "Webhook set: #{info.url} (pending updates: #{info.pending_update_count})"
  end

  desc "Set the bot's description, short description and command menu from the locales"
  task set_profile: :environment do
    Bot::Profile.apply(Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN")).api)
    puts "Bot profile updated"
  end
end
