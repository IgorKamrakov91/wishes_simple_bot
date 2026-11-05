require "telegram/bot"

# Telegram API URLs contain the bot token (api.telegram.org/bot<token>/...).
# When Telegram answers with something that isn't JSON (a 502 page, say),
# the gem's ResponseError puts that URL into its message and data, and
# from there it would reach any log that prints the error. Redact it at
# the source, so every log line and job failure is covered.
module TelegramTokenRedaction
  API_PATH = %r{(api\.telegram\.org/(?:file/)?bot)[^/\s"']+}

  def self.redact(value)
    case value
    when String
      text = value.gsub(API_PATH, '\1[FILTERED]')
      token = ENV["TELEGRAM_BOT_TOKEN"].presence
      token ? text.gsub(token, "[FILTERED]") : text
    when Hash then value.transform_values { |item| redact(item) }
    when Array then value.map { |item| redact(item) }
    else value
    end
  end

  module ResponseError
    def message
      TelegramTokenRedaction.redact(super)
    end

    def to_s
      TelegramTokenRedaction.redact(super)
    end

    def data
      TelegramTokenRedaction.redact(super)
    end
  end
end

Telegram::Bot::Exceptions::ResponseError.prepend(TelegramTokenRedaction::ResponseError)
