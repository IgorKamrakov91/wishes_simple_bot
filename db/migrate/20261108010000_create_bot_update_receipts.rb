class CreateBotUpdateReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :bot_update_receipts, primary_key: :update_id do |t|
      t.bigint :telegram_user_id, null: false
      t.string :result_kind, null: false, default: "processed"
      t.bigint :result_id
      t.datetime :delivered_at
      t.datetime :created_at, null: false
    end
    add_index :bot_update_receipts, :created_at
  end
end
