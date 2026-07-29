require "test_helper"

class BotHelpersTest < ActiveSupport::TestCase
  include Bot::Helpers

  test "progress_bar_string renders expected filled and empty blocks" do
    assert_equal "[🟩🟩🟩⬜⬜]", progress_bar_string(60, 5)
    assert_equal "[⬜⬜⬜⬜]", progress_bar_string(0, 4)
  end

  test "progress_bar_string clamps percentages outside the display range" do
    assert_equal "[⬜⬜⬜]", progress_bar_string(-25, 3)
    assert_equal "[🟩🟩🟩]", progress_bar_string(150, 3)
  end
end
