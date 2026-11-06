class User < ApplicationRecord
  RESERVATION_REMINDER_DAYS = [ 0, 7, 14, 30 ].freeze

  has_many :wishlists, dependent: :destroy
  has_many :items, through: :wishlists
  has_many :list_viewers, dependent: :destroy
  has_many :viewed_wishlists, through: :list_viewers, source: :wishlist

  validates :telegram_id, presence: true, uniqueness: true
  validates :reservation_reminder_days, inclusion: { in: RESERVATION_REMINDER_DAYS }

  def configure_reservation_reminders!(days)
    raise ArgumentError, "Unsupported reminder interval" unless RESERVATION_REMINDER_DAYS.include?(days)

    with_lock do
      # Replayed settings buttons must not postpone the next reminder.
      next if reservation_reminder_days == days

      update!(reservation_reminder_days: days,
              reservation_reminder_next_at: (ReminderSchedule.next_send_at(Time.current + days.days) if days.positive?))
    end
  end

  def self.find_or_create_from_telegram(data)
    find_or_initialize_by(telegram_id: data[:id]).tap do |user|
      user.assign_attributes(
        username: data[:username],
        first_name: data[:first_name],
        last_name: data[:last_name],
        last_seen_at: Time.current
      )
      user.save!
    end
  end

  def start_creating_list!
    update!(bot_state: "creating_list", bot_payload: {})
  end

  def start_renaming_list!(wishlist_id:)
    update!(bot_state: "renaming_list", bot_payload: { wishlist_id: wishlist_id })
  end

  def start_adding_item!(wishlist_id:)
    update!(bot_state: "adding_item", bot_payload: { wishlist_id: wishlist_id })
  end

  def clear_state!
    update!(bot_state: nil, bot_payload: nil)
  end

  def full_name
    full_name = [ first_name, last_name ].map(&:presence).compact.join(" ")
    full_name.presence || username.presence || "Anonymous"
  end
end
