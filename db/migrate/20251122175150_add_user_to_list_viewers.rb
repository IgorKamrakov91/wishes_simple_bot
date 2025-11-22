class AddUserToListViewers < ActiveRecord::Migration[8.1]
  def change
    add_reference :list_viewers, :user, null: false, foreign_key: true
    remove_column :list_viewers, :telegram_id
  end
end
