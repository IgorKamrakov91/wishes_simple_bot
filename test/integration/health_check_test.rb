require "test_helper"

class HealthCheckTest < ActionDispatch::IntegrationTest
  test "kamal-proxy health check endpoint responds with 200" do
    get "/up"

    assert_response :success
  end
end
