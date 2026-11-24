# A model call other than gift ideas (for now: reading a gift from a photo).
# Gift idea requests are counted by GiftSuggestion itself; together they make
# up the app-wide daily cap, checked under the same advisory lock.
class AiCall < ApplicationRecord
  KINDS = {
    # app-wide and per-person calls per day, inside the shared cap
    "photo" => { daily: 100, per_user: 20 }
  }.freeze

  belongs_to :user

  validates :kind, inclusion: { in: KINDS.keys }

  scope :today, -> { where(created_at: Time.current.in_time_zone(GiftSuggestion::TIME_ZONE).beginning_of_day..) }

  # Every model call today, whatever its kind or outcome
  def self.total_today
    GiftSuggestion.today.count + today.count
  end

  def self.daily_limit(kind)
    ENV.fetch("YANDEX_AI_#{kind.upcase}_DAILY_LIMIT", KINDS.fetch(kind)[:daily]).to_i
  end

  # Records a call of `kind` for the user if every cap allows it. Returns
  # :created, :disabled, :global_limit, :kind_limit or :user_limit. Locks
  # the user first and the app-wide count second, in the same order as gift
  # idea requests, so the two never deadlock.
  def self.reserve!(user, kind)
    kind = kind.to_s
    caps = KINDS.fetch(kind)
    return :disabled unless GiftSuggestion.enabled?

    user.with_lock do
      connection.execute("SELECT pg_advisory_xact_lock(#{GiftSuggestion::GLOBAL_LOCK_KEY})")
      today_kind = today.where(kind: kind)
      next :user_limit if today_kind.where(user: user).count >= caps[:per_user]
      next :kind_limit if today_kind.count >= daily_limit(kind)
      next :global_limit if total_today >= GiftSuggestion.global_daily_limit

      create!(user: user, kind: kind)
      :created
    end
  end
end
