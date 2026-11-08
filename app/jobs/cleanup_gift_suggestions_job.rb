class CleanupGiftSuggestionsJob < ApplicationJob
  def perform
    GiftSuggestion.where(created_at: ...GiftSuggestion::KEEP_FOR.ago).in_batches.delete_all
  end
end
