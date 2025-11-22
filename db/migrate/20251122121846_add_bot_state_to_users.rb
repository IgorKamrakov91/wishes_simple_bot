class AddBotStateToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :bot_state, :string
    add_column :users, :bot_payload, :json
  end
end
