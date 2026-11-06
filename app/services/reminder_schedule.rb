# frozen_string_literal: true

# Explicitly local to reminders; the application's storage timezone stays UTC.
module ReminderSchedule
  TIME_ZONE = "Europe/Moscow"
  OPEN_HOUR = 12
  CLOSE_HOUR = 18

  module_function

  def after_days(time, days)
    time.in_time_zone(TIME_ZONE).advance(days: days).change(hour: OPEN_HOUR)
  end

  def next_send_at(time)
    local = time.in_time_zone(TIME_ZONE)
    return local.change(hour: OPEN_HOUR) if local.hour < OPEN_HOUR
    return local.tomorrow.change(hour: OPEN_HOUR) if local.hour >= CLOSE_HOUR

    local
  end
end
