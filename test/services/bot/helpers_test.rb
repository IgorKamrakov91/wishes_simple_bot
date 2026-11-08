require "test_helper"

class BotHelpersTest < ActiveSupport::TestCase
  include Bot::Helpers

  test "progress_dots shows one dot per gift" do
    assert_equal "●●○○", progress_dots(2, 4)
    assert_equal "○○○", progress_dots(0, 3)
    assert_equal "●●●", progress_dots(3, 3)
    assert_equal "", progress_dots(0, 0)
  end

  test "progress_dots scales long lists but keeps none and all exact" do
    assert_equal "●●●●●○○○○○", progress_dots(10, 20)
    assert_equal "●○○○○○○○○○", progress_dots(1, 40)
    assert_equal "●●●●●●●●●○", progress_dots(39, 40)
    assert_equal "●●●●●●●●●●", progress_dots(40, 40)
  end
end
