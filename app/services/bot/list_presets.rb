# frozen_string_literal: true

module Bot
  # Ready list names, so a new list doesn't start with typing. The season's
  # occasion comes first; any name can still be typed instead.
  module ListPresets
    KEYS = %w[new_year birthday wishes].freeze
    # New Year lists make sense from November to mid-January
    NEW_YEAR_SEASON = ->(date) { date.month >= 11 || (date.month == 1 && date.day <= 15) }

    module_function

    def ordered(date = Time.current.in_time_zone(ReminderSchedule::TIME_ZONE).to_date)
      NEW_YEAR_SEASON.call(date) ? KEYS : %w[birthday new_year wishes]
    end

    def title(key)
      I18n.t("bot.list_presets.#{key}.title")
    end

    def label(key)
      I18n.t("bot.list_presets.#{key}.button")
    end
  end
end
