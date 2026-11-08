require "test_helper"
require "mocha/minitest"

class YandexAiClientTest < ActiveSupport::TestCase
  setup do
    @client = YandexAi::Client.new(api_key: "secret-key", folder_id: "folder1", model: "aliceai-llm-flash")
  end

  def respond(klass, code, body)
    response = klass.new("1.1", code, "")
    response.stubs(:body).returns(body)
    response
  end

  test "posts to AI Studio with the API key and logging turned off" do
    request = nil
    http = mock("http")
    http.expects(:request).with { |req| request = req; true }
      .returns(respond(Net::HTTPOK, "200", { choices: [ { message: { content: "hi" }, finish_reason: "stop" } ] }.to_json))
    Net::HTTP.expects(:start).with("ai.api.cloud.yandex.net", 443, has_entries(use_ssl: true)).yields(http)

    assert_equal "hi", @client.chat([ { role: "user", content: "x" } ], temperature: 0.5, max_tokens: 10)
    assert_equal "Api-Key secret-key", request["Authorization"]
    assert_equal "folder1", request["x-folder-id"]
    assert_equal "false", request["x-data-logging-enabled"]
    assert_equal "gpt://folder1/aliceai-llm-flash", JSON.parse(request.body)["model"]
  end

  test "errors carry a short code and no response text" do
    cases = {
      respond(Net::HTTPUnauthorized, "401", "PRIVATE") => "http_401",
      respond(Net::HTTPOK, "200", "not json") => "bad_json",
      respond(Net::HTTPOK, "200", { choices: [ { message: { content: "x" }, finish_reason: "length" } ] }.to_json) => "truncated"
    }
    cases.each do |response, code|
      http = stub(request: response)
      Net::HTTP.stubs(:start).yields(http)
      error = assert_raises(YandexAi::Client::Error) { @client.chat([], temperature: 0, max_tokens: 1) }
      assert_equal code, error.code
      refute_includes error.message, "PRIVATE"
    end

    Net::HTTP.stubs(:start).raises(Net::ReadTimeout)
    assert_equal "timeout", assert_raises(YandexAi::Client::Error) { @client.chat([], temperature: 0, max_tokens: 1) }.code
  end
end
