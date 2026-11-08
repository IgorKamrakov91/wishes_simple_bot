require "test_helper"
require "mocha/minitest"

class YandexAiGiftIdeasTest < ActiveSupport::TestCase
  setup do
    @client = mock("YandexAiClient")
  end

  test "sends only the list and gift titles as data and returns clean ideas" do
    sent = nil
    @client.expects(:chat).with { |messages, **options| sent = [ messages, options ]; true }
      .returns({ ideas: [ " Лампа  для чтения ", "Плед", "плед", "", "https://ozon.ru/x", "x" * 101, "Термокружка", "Ежедневник", "Пазл", "Лишняя" ] }.to_json)

    ideas = YandexAi::GiftIdeas.new(client: @client).call("День рождения", [ "Плед", "Книга" ])

    assert_equal [ "Лампа для чтения", "Термокружка", "Ежедневник", "Пазл", "Лишняя" ], ideas
    messages, options = sent
    assert_equal({ "list" => "День рождения", "gifts" => [ "Плед", "Книга" ] }, JSON.parse(messages.last[:content]))
    assert_equal "system", messages.first[:role]
    assert_equal "json_schema", options[:response_format][:type]
  end

  test "sends earlier ideas and drops any the model repeats" do
    sent = nil
    @client.expects(:chat).with { |messages, **| sent = JSON.parse(messages.last[:content]); true }
      .returns('{"ideas":["Лампа", "кружка", "Пазл"]}')

    ideas = YandexAi::GiftIdeas.new(client: @client).call("List", [ "Плед" ], suggested: [ "Лампа", "Кружка" ])

    assert_equal [ "Пазл" ], ideas
    assert_equal [ "Лампа", "Кружка" ], sent["suggested"]
    assert_includes YandexAi::GiftIdeas::SYSTEM_PROMPT, "suggested"
  end

  test "keeps only the last 20 gifts" do
    titles = (1..25).map { |n| "Gift #{n}" }
    @client.expects(:chat).with { |messages, **| JSON.parse(messages.last[:content])["gifts"] == titles.last(20) }
      .returns('{"ideas":["Лампа"]}')

    YandexAi::GiftIdeas.new(client: @client).call("List", titles)
  end

  test "accepts JSON inside a code fence" do
    @client.stubs(:chat).returns("```json\n{\"ideas\": [\"Лампа\"]}\n```")

    assert_equal [ "Лампа" ], YandexAi::GiftIdeas.new(client: @client).call("List", [])
  end

  test "unusable answers are errors, not ideas" do
    [ "not json", '{"ideas": []}', '{"ideas": ["Плед"]}', '{"other": 1}' ].each do |answer|
      @client.stubs(:chat).returns(answer)
      error = assert_raises(YandexAi::Client::Error) { YandexAi::GiftIdeas.new(client: @client).call("List", [ "Плед" ]) }
      assert_includes %w[bad_answer no_ideas], error.code, answer
    end
  end
end
