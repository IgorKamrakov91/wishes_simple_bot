class OnboardingNudge < ApplicationRecord
  belongs_to :user
  belongs_to :wishlist, optional: true
  belongs_to :gift_suggestion, optional: true

  scope :ready, -> {
    where(sent_at: nil, claimed_at: nil).where("attempts < 3")
      .where("retry_at IS NULL OR retry_at <= ?", Time.current)
  }

  def self.candidates
    User.where(onboarding_eligible: true, first_item_at: nil, notify_onboarding: true)
      .where.not(first_private_start_at: nil).where(first_private_start_at: ..24.hours.ago)
      .where("last_seen_at IS NULL OR last_seen_at <= ?", 24.hours.ago)
  end

  def eligible?
    user.onboarding? && user.notify_onboarding? && user.first_private_start_at.present?
  end

  def due_at
    [ user.first_private_start_at, user.last_seen_at ].compact.max + 24.hours
  end

  def current_list
    user.wishlists.where.missing(:items).order(id: :desc).first
  end

  def fallback
    I18n.t("bot.onboarding_nudge.examples", locale: locale)
  end
end
