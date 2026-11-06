class BirthdayReminderDelivery < ApplicationRecord
  belongs_to :recipient, class_name: "User"
  belongs_to :owner, class_name: "User"

  scope :ready, -> {
    where(sent_at: nil, claimed_at: nil).where("attempts < 3")
      .where("retry_at IS NULL OR retry_at <= ?", Time.current)
  }
end
