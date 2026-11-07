class AddLastListCreationMessageIdToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :last_list_creation_message_id, :bigint
  end
end
