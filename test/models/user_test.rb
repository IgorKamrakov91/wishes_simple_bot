require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "full_name returns first and last name when present" do
    user = User.new(first_name: "John", last_name: "Doe", username: "johndoe")
    assert_equal "John Doe", user.full_name
  end

  test "full_name returns first name when last name is missing" do
    user = User.new(first_name: "John", username: "johndoe")
    assert_equal "John", user.full_name
  end

  test "full_name returns username when names are missing" do
    user = User.new(username: "johndoe")
    assert_equal "johndoe", user.full_name
  end

  test "full_name returns Anonymous when all are missing" do
    user = User.new
    assert_equal "Anonymous", user.full_name
  end
end
