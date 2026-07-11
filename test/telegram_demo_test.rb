# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/providers/manual_provider"
require "zero_x_da/market/telegram/broker_bot"
require "zero_x_da/market/telegram/client_bot"
require "zero_x_da/market/telegram/demo_flow"
require "zero_x_da/market/telegram/memory_store"

class TelegramDemoTest < Minitest::Test
  class FakeAPI
    attr_reader :messages, :callback_answers

    def initialize
      @messages = []
      @callback_answers = []
    end

    def send_message(**attributes)
      @messages << attributes
      { "message_id" => @messages.length }
    end

    def answer_callback_query(**attributes)
      @callback_answers << attributes
      true
    end
  end

  include KernelFixture

  def setup
    @clock = MutableClock.new
    @provider = ZeroXDA::Market::Providers::ManualProvider.new(
      key: "manual.test",
      clock: @clock,
      quote_terms: { fulfillment: "manual", payment: "demo" }
    )
    @kernel, = build_kernel(
      provider: @provider,
      clock: @clock,
      capability: "manual.fulfillment"
    )
    @store = ZeroXDA::Market::Telegram::MemoryStore.new
    @client_api = FakeAPI.new
    @broker_api = FakeAPI.new
    @flow = ZeroXDA::Market::Telegram::DemoFlow.new(
      kernel: @kernel,
      provider: @provider,
      store: @store,
      client_api: @client_api,
      broker_api: @broker_api,
      clock: @clock
    )
    @client_bot = ZeroXDA::Market::Telegram::ClientBot.new(
      flow: @flow,
      api: @client_api
    )
    @broker_bot = ZeroXDA::Market::Telegram::BrokerBot.new(
      flow: @flow,
      api: @broker_api
    )
  end

  def test_runs_the_complete_client_and_broker_demo
    @broker_bot.handle(message_update(1, chat_id: 101, text: "/start", username: "broker_one"))
    @client_bot.handle(message_update(2, chat_id: 201, text: "100 stars", username: "client_one"))

    offer = message_with_callback(@broker_api, "accept:", chat_id: "101")
    @broker_bot.handle(
      callback_update(3, chat_id: 101, callback_id: "accept-1", data: callback_data(offer))
    )

    payment = message_with_callback(@client_api, "pay:", chat_id: "201")
    @client_bot.handle(
      callback_update(4, chat_id: 201, callback_id: "pay-1", data: callback_data(payment))
    )

    completion = message_with_callback(@broker_api, "complete:", chat_id: "101")
    @broker_bot.handle(
      callback_update(5, chat_id: 101, callback_id: "complete-1", data: callback_data(completion))
    )

    task = @provider.tasks.fetch(0)
    demo_order = @store.fetch_demo_order(task.id)
    assert_equal "completed", task.status
    assert_equal "completed", demo_order.status
    assert_equal "succeeded", @kernel.find_order(demo_order.order_id).status
    assert_includes @client_api.messages.last.fetch(:text), "отримано: «100 stars»"
    assert_includes @broker_api.messages.last.fetch(:text), "виконання зафіксовано"
  end

  def test_only_one_ready_broker_can_accept_a_broadcast_offer
    @broker_bot.handle(message_update(1, chat_id: 101, text: "/start", username: "one"))
    @broker_bot.handle(message_update(2, chat_id: 102, text: "/start", username: "two"))
    @client_bot.handle(message_update(3, chat_id: 201, text: "tg premium 12 months"))

    first_offer = message_with_callback(@broker_api, "accept:", chat_id: "101")
    second_offer = message_with_callback(@broker_api, "accept:", chat_id: "102")
    @broker_bot.handle(
      callback_update(4, chat_id: 101, callback_id: "accept-1", data: callback_data(first_offer))
    )
    @broker_bot.handle(
      callback_update(5, chat_id: 102, callback_id: "accept-2", data: callback_data(second_offer))
    )

    task = @provider.tasks.fetch(0)
    assert_equal "telegram:101", task.claimed_by
    pay_prompts = @client_api.messages.count do |message|
      callback_data(message)&.start_with?("pay:")
    end
    assert_equal 1, pay_prompts
    rejected = @broker_api.callback_answers.find do |answer|
      answer[:callback_query_id] == "accept-2"
    end
    assert rejected.fetch(:show_alert)
    assert_includes rejected.fetch(:text), "інший брокер"
  end

  def test_a_new_ready_broker_receives_a_request_that_was_queued_offline
    @client_bot.handle(message_update(1, chat_id: 201, text: "7.7 ton"))

    assert_empty @broker_api.messages
    assert_includes @client_api.messages.last.fetch(:text), "активних брокерів"

    @broker_bot.handle(message_update(2, chat_id: 101, text: "/start"))

    offer = message_with_callback(@broker_api, "accept:", chat_id: "101")
    assert_includes offer.fetch(:text), "7.7 ton"
  end

  def test_offline_broker_does_not_receive_new_offers
    @broker_bot.handle(message_update(1, chat_id: 101, text: "/start"))
    @broker_bot.handle(message_update(2, chat_id: 101, text: "/offline"))
    messages_before_request = @broker_api.messages.length

    @client_bot.handle(message_update(3, chat_id: 201, text: "100 stars"))

    assert_equal messages_before_request, @broker_api.messages.length
  end

  private

  def message_update(update_id, chat_id:, text:, username: nil)
    from = {
      "id" => chat_id,
      "first_name" => "Test"
    }
    from["username"] = username if username
    {
      "update_id" => update_id,
      "message" => {
        "message_id" => update_id,
        "chat" => { "id" => chat_id, "type" => "private" },
        "from" => from,
        "text" => text
      }
    }
  end

  def callback_update(update_id, chat_id:, callback_id:, data:)
    {
      "update_id" => update_id,
      "callback_query" => {
        "id" => callback_id,
        "from" => { "id" => chat_id, "first_name" => "Test" },
        "message" => {
          "message_id" => update_id,
          "chat" => { "id" => chat_id, "type" => "private" }
        },
        "data" => data
      }
    }
  end

  def message_with_callback(api, prefix, chat_id:)
    api.messages.reverse.find do |message|
      message.fetch(:chat_id).to_s == chat_id && callback_data(message)&.start_with?(prefix)
    end || raise("message with #{prefix} callback was not found")
  end

  def callback_data(message)
    message.dig(:reply_markup, "inline_keyboard", 0, 0, "callback_data")
  end
end
