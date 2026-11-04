# frozen_string_literal: true

module Bot
  # Telegram sends the secret registered with setWebhook in every update,
  # so the endpoint can tell real updates from forged ones.
  module Webhook
    SECRET_HEADER = "X-Telegram-Bot-Api-Secret-Token"
    ALLOWED_UPDATES = %w[message callback_query inline_query].freeze

    module_function

    # An explicit TELEGRAM_WEBHOOK_SECRET wins; otherwise the secret is derived
    # from the bot token, so deploys need no extra configuration.
    def secret
      explicit = ENV["TELEGRAM_WEBHOOK_SECRET"].presence
      return explicit if explicit

      token = ENV["TELEGRAM_BOT_TOKEN"].presence
      OpenSSL::HMAC.hexdigest("SHA256", token, "telegram-webhook") if token
    end

    def authentic?(request)
      expected = secret
      given = request.headers[SECRET_HEADER].to_s
      expected.present? && ActiveSupport::SecurityUtils.secure_compare(given, expected)
    end
  end
end
