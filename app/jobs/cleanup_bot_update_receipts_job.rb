class CleanupBotUpdateReceiptsJob < ApplicationJob
  def perform
    BotUpdateReceipt.where(created_at: ...2.days.ago).in_batches.delete_all
  end
end
