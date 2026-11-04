# frozen_string_literal: true

module Bot
  # What Telegram shows before the first /start: the description, the short
  # description on the profile and in shared links, and the command menu.
  # The bot speaks Russian, so everyone gets the Russian texts; languages
  # that once had their own texts get them removed and fall back to these.
  module Profile
    COMMANDS = %w[start my new cancel help].freeze
    REMOVED_LANGUAGES = %w[en].freeze

    module_function

    def apply(api)
      I18n.with_locale(:ru) do
        api.set_my_commands(commands: commands)
        api.set_my_description(description: I18n.t("bot.profile.description"))
        api.set_my_short_description(short_description: I18n.t("bot.profile.short_description"))
      end

      # An empty text removes the language-specific one
      REMOVED_LANGUAGES.each do |language_code|
        api.delete_my_commands(language_code: language_code)
        api.set_my_description(description: "", language_code: language_code)
        api.set_my_short_description(short_description: "", language_code: language_code)
      end
    end

    def commands
      COMMANDS.map { |name| { command: name, description: I18n.t("bot.profile.commands.#{name}") } }
    end
  end
end
