# A private, expiring proposal. Only save_gift! publishes an Item. Recognition
# uses an explicit version so cancelled, replaced or manually edited work wins.
class PhotoGiftDraft < ApplicationRecord
  STATUSES = %w[awaiting_consent pending ready failed saved cancelled].freeze
  ACTIVE_STATUSES = %w[awaiting_consent pending ready failed].freeze
  FIELDS = Item::EDITABLE_FIELDS
  KEEP_FOR = 24.hours
  RECOGNITION_DEADLINE = 2.minutes

  belongs_to :user
  belongs_to :wishlist, optional: true
  belongs_to :item, optional: true
  validates :status, inclusion: { in: STATUSES }
  validates :media_kind, inclusion: { in: %w[photo document] }
  validates :media_status, inclusion: { in: %w[pending processing ready failed] }
  validates :file_id, :chat_id, :message_id, :locale, :expires_at, presence: true
  validates :version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  scope :active, -> { where(status: ACTIVE_STATUSES).where("expires_at > ?", Time.current) }

  # Every move to pending (first photo after consent, consent, retry) is read
  # once the change is committed; the job ignores versions that moved on.
  before_save :mark_pending_start, if: -> { will_save_change_to_status? && status == "pending" }
  after_commit :enqueue_recognition, if: -> { saved_change_to_status? && status == "pending" }

  def self.enabled?
    ENV["PHOTO_GIFTS_ENABLED"] == "true"
  end

  def self.start!(user, **attributes)
    user.with_lock do
      existing = user.photo_gift_drafts.find_by(chat_id: attributes[:chat_id], message_id: attributes[:message_id])
      next existing if existing

      user.photo_gift_drafts.active.update_all("status = 'cancelled', version = version + 1")
      target = if user.bot_state == "adding_item"
        user.wishlists.find(user.bot_payload.fetch("wishlist_id"))
      else
        user.wishlists.order(updated_at: :desc, id: :desc).first
      end
      draft = user.photo_gift_drafts.create!(**attributes, wishlist: target,
        result: caption_result(attributes[:caption]).merge("new_list" => target.nil?),
        expires_at: KEEP_FOR.from_now, locale: I18n.locale.to_s,
        status: user.photo_ai_consented_at? ? "pending" : "awaiting_consent")
      user.update!(bot_state: "photo_gift", bot_payload: { "photo_gift_draft_id" => draft.id })
      draft
    end
  end

  def self.caption_result(caption)
    text = caption.to_s.strip
    return {} if text.empty?

    link = text[%r{https?://\S+}i]
    source_link = link
    if !link && Bot::StateHandler::BARE_LINK.match?(text) && text.match?(/[\/?#]/)
      source_link = text
      link = "https://#{text}"
    end
    values = {}
    if link && link.length <= Item::URL_LIMIT && Item.web_uri(link)
      values["url"] = link
      text = text.sub(source_link, "").strip
    end
    values["title"] = text.first(Item::TITLE_LIMIT) if text.present?
    values
  end

  def editable?
    ACTIVE_STATUSES.include?(status) && expires_at > Time.current
  end

  # PR2 hook: enqueue recognition after this transition commits. PR1 deliberately
  # renders the manual review immediately and never calls the model.
  def start_recognition!(expected_version:)
    return false unless user.photo_ai_consented_at?

    change!(expected_version) { update!(status: "pending", error_code: nil, version: version + 1) }
  end

  def consent!(expected_version:)
    user.with_lock do
      change!(expected_version) do
        user.update!(photo_ai_consented_at: Time.current)
        # Integration point for PR2; enqueue only after the enclosing commit.
        update!(status: "pending", error_code: nil, version: version + 1)
      end
    end
  end

  def manual!(expected_version:)
    change!(expected_version) { update!(status: "ready", error_code: nil, version: version + 1) }
  end

  def retry_recognition!(expected_version:)
    return false unless user.photo_ai_consented_at?

    change!(expected_version) do
      next false unless status == "failed" && !result["retry_used"]

      update!(status: "pending", error_code: nil, result: result.merge("retry_used" => true), version: version + 1)
    end
  end

  def fail_recognition!(code, expected_version:)
    change!(expected_version) do
      next false unless status == "pending"

      update!(status: "failed", error_code: code.to_s.first(40), version: version + 1)
    end
  end

  def apply_recognition!(title:, price:, description:, expected_version:)
    change!(expected_version) do
      next false unless status == "pending"

      values = { "title" => title, "price" => price, "description" => description }.compact
      values = values.reject { |key, _| result[key].present? }
      validate_fields!(fields.merge(values))
      update!(result: result.merge(values), status: "ready", version: version + 1, error_code: nil)
    end
  end

  def update_field!(field, value, expected_version:)
    raise ArgumentError unless FIELDS.include?(field)

    change!(expected_version) do
      values = fields.merge(field => value)
      validate_fields!(values, require_title: field == "title")
      update!(result: result.merge(field => value), status: "ready", version: version + 1)
    end
  end

  def select_list!(wishlist_id, expected_version:)
    change!(expected_version) do
      target = user.wishlists.find(wishlist_id) unless wishlist_id.zero?
      update!(wishlist: target, result: result.merge("new_list" => target.nil?), version: version + 1)
    end
  end

  def remove_photo!(expected_version:)
    change!(expected_version) do
      update!(result: result.merge("without_photo" => true), version: version + 1)
    end
  end

  def cancel!(expected_version:)
    change!(expected_version) { update!(status: "cancelled", version: version + 1) }
  end

  def fields
    result.slice(*FIELDS)
  end

  def save_gift!(expected_version:)
    user.with_lock do
      with_lock do
        return [ :already, user.items.find_by(id: item_id) ] if status == "saved"
        return [ :stale, nil ] unless editable? && version == expected_version && status != "awaiting_consent"
        return [ :photo_pending, nil ] if !result["without_photo"] && media_status != "ready"

        validate_fields!(fields, require_title: true)
        target = if result["new_list"]
          user.wishlists.create!(title: I18n.t("bot.photo_gift.default_list", locale: locale))
        else
          user.wishlists.find(wishlist_id)
        end
        gift = target.items.create!(**fields.symbolize_keys,
          photo_file_id: (photo_file_id unless result["without_photo"]))
        update!(status: "saved", item: gift, wishlist: target, version: version + 1)
        if user.bot_payload&.dig("photo_gift_draft_id") == id
          user.update!(bot_state: nil, bot_payload: nil)
        end
        [ :saved, gift ]
      end
    end
  end

  # Pending for longer than the job's deadline: the job was lost. Counted from
  # the move to pending, so later edits don't restart the wait.
  def recognition_stalled?
    return false unless status == "pending"

    started = Time.zone.parse(result["pending_at"].to_s) rescue nil
    (started || created_at) < RECOGNITION_DEADLINE.ago
  end

  private

  def mark_pending_start
    self.result = result.merge("pending_at" => Time.current.iso8601(3))
  end

  def enqueue_recognition
    PhotoGiftRecognitionJob.perform_later(id, version)
  end

  def validate_fields!(values, require_title: false)
    attributes = values.symbolize_keys
    attributes[:title] = "Draft" if !require_title && attributes[:title].blank?
    Item.new(**attributes, wishlist: wishlist || Wishlist.new(user: user, title: "Draft")).validate!
  end

  def change!(expected_version)
    with_lock do
      next false unless editable? && version == expected_version

      yield
    end
  end
end
