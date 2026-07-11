# frozen_string_literal: true

require_relative "../core/kernel"
require_relative "../providers/manual_provider"

module ZeroXDA
  module Market
    module Telegram
      class DemoFlow
        CAPABILITY = "manual.fulfillment"
        MAX_ITEM_LENGTH = 500

        def initialize(kernel:, provider:, store:, client_api:, broker_api:, clock:)
          @kernel = kernel
          @provider = provider
          @store = store
          @client_api = client_api
          @broker_api = broker_api
          @clock = clock
        end

        def submit_request(client:, item:)
          normalized_item = normalize_item(item)
          intent = @kernel.create_intent(
            capability: CAPABILITY,
            payload: {
              "item" => normalized_item,
              "mode" => "demo"
            },
            context: client_context(client)
          )
          quote = @kernel.quote_intent(intent.id)
          order = @kernel.accept_quote(quote.id)
          pending = @kernel.execute_order(order.id)
          task_id = pending.progress.fetch("reference")
          demo_order = @store.insert_demo_order(
            task_id: task_id,
            order_id: order.id,
            client_chat_id: client.fetch(:chat_id),
            at: current_time
          )

          @client_api.send_message(
            chat_id: demo_order.client_chat_id,
            text: "🔎 запит створено\n\n«#{normalized_item}»\n\nшукаю активного брокера…"
          )

          brokers = @store.ready_brokers
          brokers.each { |broker| send_offer(broker, @provider.fetch_task(task_id)) }
          if brokers.empty?
            @client_api.send_message(
              chat_id: demo_order.client_chat_id,
              text: "активних брокерів поки немає. запит збережено — його побачить перший broker у ready."
            )
          end

          demo_order
        end

        def ready_broker(profile)
          broker = @store.register_broker(
            chat_id: profile.fetch(:chat_id),
            user_id: profile.fetch(:user_id),
            username: profile[:username],
            display_name: profile.fetch(:display_name),
            at: current_time
          )
          @broker_api.send_message(
            chat_id: broker.chat_id,
            text: "zeroxda-market · broker\n\nстатус: ready 🟢\nнові пропозиції надходитимуть сюди.",
            reply_markup: button("⏸ offline", "status:offline")
          )
          @store.pending_demo_orders.each do |order|
            task = @provider.fetch_task(order.task_id)
            send_offer(broker, task) if task.status == "pending"
          end
          broker
        end

        def offline_broker(chat_id)
          broker = @store.set_broker_status(
            chat_id: chat_id,
            status: "offline",
            at: current_time
          )
          @broker_api.send_message(
            chat_id: broker.chat_id,
            text: "статус: offline ⚪️\nпропозиції призупинено.",
            reply_markup: button("▶️ ready", "status:ready")
          )
          broker
        end

        def accept(task_id:, broker_chat_id:)
          broker = @store.fetch_broker(broker_chat_id)
          unless broker.status == "ready"
            raise conflict("broker_not_ready", "broker must be ready", task_id)
          end

          task = @provider.claim_task(task_id, assignee: assignee(broker.chat_id))
          order, changed = @store.assign_demo_order(
            task_id: task.id,
            broker_chat_id: broker.chat_id,
            at: current_time
          )
          return :already_accepted unless changed

          @client_api.send_message(
            chat_id: order.client_chat_id,
            text: "🤝 брокера знайдено\n\n«#{item(task)}»\n\nпідтвердь demo-payment:",
            reply_markup: button("💳 оплатити (demo)", "pay:#{task.id}")
          )
          @broker_api.send_message(
            chat_id: broker.chat_id,
            text: "🤝 пропозицію прийнято\n\n«#{item(task)}»\n\nочікую demo-payment клієнта…"
          )
          :accepted
        rescue Core::Conflict => error
          return :unavailable if error.code == "task_already_claimed"

          raise
        end

        def pay(task_id:, client_chat_id:)
          order, changed = @store.pay_demo_order(
            task_id: task_id,
            client_chat_id: client_chat_id,
            at: current_time
          )
          return :already_paid unless changed

          task = @provider.fetch_task(order.task_id)
          @client_api.send_message(
            chat_id: order.client_chat_id,
            text: "💳 demo-payment успішний\nреальні кошти не використовувались.\n\nочікую виконання брокером…"
          )
          @broker_api.send_message(
            chat_id: order.broker_chat_id,
            text: "💳 demo-payment підтверджено\n\n«#{item(task)}»\n\nвиконай запит і підтвердь:",
            reply_markup: button("✅ completed", "complete:#{task.id}")
          )
          :paid
        end

        def complete(task_id:, broker_chat_id:)
          order = @store.fetch_demo_order(task_id)
          unless order.broker_chat_id == broker_chat_id.to_s
            raise conflict("telegram_actor_mismatch", "demo order belongs to another broker", task_id)
          end
          return :already_completed if order.status == "completed"
          unless order.status == "processing"
            raise conflict("payment_required", "demo payment has not been confirmed", task_id)
          end

          task = @provider.complete_task(
            task_id,
            reference: "telegram:broker:#{broker_chat_id}",
            data: { "delivered" => true, "mode" => "demo" }
          )
          @kernel.execute_order(order.order_id)
          completed, changed = @store.complete_demo_order(
            task_id: task_id,
            broker_chat_id: broker_chat_id,
            at: current_time
          )
          return :already_completed unless changed

          @client_api.send_message(
            chat_id: completed.client_chat_id,
            text: "✅ виконано\n\nотримано: «#{item(task)}»"
          )
          @broker_api.send_message(
            chat_id: completed.broker_chat_id,
            text: "✅ виконання зафіксовано."
          )
          :completed
        end

        private

        def send_offer(broker, task)
          username = task.context["client_username"]
          client = username && !username.empty? ? "@#{username}" : "telegram user"
          @broker_api.send_message(
            chat_id: broker.chat_id,
            text: "📨 нова пропозиція\n\n«#{item(task)}»\nклієнт: #{client}",
            reply_markup: button("🤝 accept", "accept:#{task.id}")
          )
        end

        def normalize_item(value)
          unless value.is_a?(String)
            raise ArgumentError, "request must be text"
          end

          normalized = value.strip
          raise ArgumentError, "request must not be empty" if normalized.empty?
          if normalized.length > MAX_ITEM_LENGTH
            raise ArgumentError, "request is too long"
          end

          normalized
        end

        def client_context(client)
          context = {
            "transport" => "telegram",
            "client_chat_id" => client.fetch(:chat_id).to_s,
            "client_user_id" => client.fetch(:user_id).to_s
          }
          username = client[:username]
          context["client_username"] = username.to_s unless username.nil? || username.to_s.empty?
          context
        end

        def item(task)
          task.payload.fetch("item")
        end

        def assignee(chat_id)
          "telegram:#{chat_id}"
        end

        def button(text, callback_data)
          {
            "inline_keyboard" => [
              [{ "text" => text, "callback_data" => callback_data }]
            ]
          }
        end

        def conflict(code, message, task_id)
          Core::Conflict.new(
            message,
            code: code,
            details: { resource: "telegram_demo_order", id: task_id.to_s }
          )
        end

        def current_time
          value = @clock.call
          raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

          value.getutc
        end
      end
    end
  end
end
