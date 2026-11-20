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

  # Another window can be given for reminders that read better at another
  # time of day; hours are Moscow time, the close hour is not included.
  def next_send_at(time, open: OPEN_HOUR, close: CLOSE_HOUR)
    local = time.in_time_zone(TIME_ZONE)
    return local.change(hour: open) if local.hour < open
    return local.tomorrow.change(hour: open) if local.hour >= close

    local
  end
end
