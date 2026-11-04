# frozen_string_literal: true

module Bot
  # What Telegram shows before the first /start: the description, the short
  # description on the profile and in shared links, and the command menu.
  # Texts live in the locales; Russian is the default for every language,
  # English users get the English texts.
  module Profile
    COMMANDS = %w[start my new cancel help].freeze
    LANGUAGES = { nil => :ru, "en" => :en }.freeze

    module_function

    def apply(api)
      LANGUAGES.each do |language_code, locale|
        I18n.with_locale(locale) do
          scope = { language_code: language_code }.compact
          api.set_my_commands(commands: commands, **scope)
          api.set_my_description(description: I18n.t("bot.profile.description"), **scope)
          api.set_my_short_description(short_description: I18n.t("bot.profile.short_description"), **scope)
        end
      end
    end

    def commands
      COMMANDS.map { |name| { command: name, description: I18n.t("bot.profile.commands.#{name}") } }
    end
  end
end
