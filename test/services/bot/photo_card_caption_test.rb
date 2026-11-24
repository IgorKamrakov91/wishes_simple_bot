require "test_helper"

class BotPhotoCardCaptionTest < ActiveSupport::TestCase
  test "a caption that fits keeps its HTML" do
    assert_equal [ "🎁 <b>Lamp &amp; shade</b>", "HTML" ], Bot::Context.caption("🎁 <b>Lamp &amp; shade</b>")
  end

  test "a caption that doesn't fit goes as plain text, never cut inside a tag or an entity" do
    html = "🎁 <b>#{"A &amp; B " * 120}</b>"
    caption, parse_mode = Bot::Context.caption(html)

    assert_nil parse_mode
    assert_operator caption.length, :<=, Bot::Context::CAPTION_LIMIT
    refute_includes caption, "<b>"
    refute_includes caption, "&amp"
    assert caption.start_with?("🎁 A & B")
  end
end
