# frozen_string_literal: true

require "bigdecimal"
require "time"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Marketplace
      QuoteResult = Struct.new(
        :quote,
        :reservation,
        :product,
        :recipient,
        :unit_price_usdt,
        :total_price_usdt,
        keyword_init: true
      )
      OrderResult = Struct.new(:order, :reservation, keyword_init: true)

      class Service
        CAPABILITY = "manual.fulfillment"
        CLIENT_PRICE_SCALE = 6

        def initialize(
          kernel:, catalog:, pricing:, listings:, settlement_provider: nil,
          recipient_resolver: nil, payment_terms_provider: nil
        )
          @kernel = kernel
          @catalog = catalog
          @pricing = pricing
          @listings = listings
          @settlement_provider = settlement_provider
          @recipient_resolver = recipient_resolver
          @payment_terms_provider = payment_terms_provider
        end

        def quote(customer_user_id:, sku:, quantity: 1, recipient: nil, context: {})
          raise ArgumentError, "context must be an object" unless context.is_a?(Hash)

          customer_id = Core::RecordSupport.identifier(
            customer_user_id.to_s,
            field: "customer user id"
          )
          product = @catalog.find_product(sku.to_s)
          unless product.status == "active" && product.marketable?
            raise Core::Conflict.new(
              "product is unavailable",
              code: "product_unavailable",
              details: { sku: product.sku }
            )
          end

          requested_quantity = quantity_value(quantity)
          enforce_purchase_quantity!(product, requested_quantity)
          resolved_recipient = resolve_recipient(product, customer_id, recipient)

          price = @pricing.current_prices[product.sku]
          unless price
            raise Core::Conflict.new(
              "product has no active client price",
              code: "product_unpriced",
              details: { sku: product.sku }
            )
          end

          unit_price = price.amount_usdt.round(
            CLIENT_PRICE_SCALE,
            BigDecimal::ROUND_CEILING
          )
          total_price = (unit_price * requested_quantity).round(
            CLIENT_PRICE_SCALE,
            BigDecimal::ROUND_CEILING
          )
          payload = {
            "action" => "purchase",
            "product" => {
              "sku" => product.sku,
              "name" => product.name,
              "quantity" => requested_quantity.to_s("F"),
              "unit_price_usdt" => unit_price.to_s("F"),
              "total_price_usdt" => total_price.to_s("F"),
              "currency" => "USDT"
            }
          }
          payload["recipient"] = resolved_recipient.to_h if resolved_recipient
          intent = @kernel.create_intent(
            capability: CAPABILITY,
            payload: payload,
            context: stringify_keys(context).merge("customer_user_id" => customer_id)
          )
          quote = @kernel.quote_intent(intent.id)
          unless quote.expires_at
            raise Core::ProviderContractError.new(
              "marketplace quotes require an expiration"
            )
          end

          @kernel.settlement_cost(quote) if @kernel.respond_to?(:settlement_cost)

          reservation = @listings.reserve(
            customer_user_id: customer_id,
            quote_id: quote.id,
            sku: product.sku,
            quantity: requested_quantity,
            expires_at: quote.expires_at,
            client_total_price_usdt: total_price
          )
          QuoteResult.new(
            quote: quote,
            reservation: reservation,
            product: product,
            recipient: resolved_recipient,
            unit_price_usdt: unit_price,
            total_price_usdt: total_price
          )
        end

        def accept(customer_user_id:, quote_id:)
          customer_id = normalized_customer_id(customer_user_id)
          reservation = @listings.reservation_for_quote(quote_id) ||
                        raise(Core::NotFound.new("listing_reservation", quote_id))
          ensure_owner!(reservation, customer_id)
          quote = @kernel.find_quote(quote_id)
          intent = @kernel.find_intent(quote.intent_id)
          product = intent.payload.fetch("product")
          payment = {
            "status" => "pending",
            "amount" => product.fetch("total_price_usdt"),
            "currency" => product.fetch("currency"),
            "expires_at" => reservation.expires_at.iso8601(6),
            "idempotency_key" => "quotes/#{quote_id}/payment"
          }
          provider_terms = @payment_terms_provider&.quote(
            amount_usdt: product.fetch("total_price_usdt")
          )
          payment["provider"] = provider_terms if provider_terms
          payment["settlement_required"] = true if @settlement_provider && !provider_terms
          order = @kernel.accept_quote(
            quote_id,
            initial_status: "payment_pending",
            payment: payment
          )
          reservation = @listings.await_payment(
            customer_user_id: customer_id,
            quote_id: quote_id,
            order_id: order.id
          )
          @kernel.charge_settlement(order.id) if @settlement_provider && !provider_terms
          OrderResult.new(order: order, reservation: reservation)
        rescue StandardError
          begin
            if order && %w[accepted payment_pending].include?(order.status)
              @kernel.cancel_order(order.id)
            end
            @listings.release(customer_user_id: customer_id, quote_id: quote_id) if reservation
          rescue StandardError
            nil
          end
          raise
        end

        # Trusted provider confirmation scoped to the owning customer. Provider
        # evidence must match the immutable provider terms snapshotted when the
        # order was accepted. Client-side invoice callbacks are never accepted
        # as payment proof; the channel adapter calls this only after receiving
        # the provider's authoritative server-side payment event.
        def confirm_customer_payment(
          customer_user_id:, order_id:, reference:, provider:, amount:, currency:, data: {}
        )
          customer_id = normalized_customer_id(customer_user_id)
          reservation = @listings.reservation_for_order(order_id) ||
                        raise(Core::NotFound.new("marketplace_order", order_id))
          ensure_owner!(reservation, customer_id)
          before = @kernel.find_order(order_id)
          ensure_payment_required!(before)
          validate_provider_payment!(
            before,
            provider: provider,
            amount: amount,
            currency: currency
          )

          if before.payment["status"] == "confirmed"
            unless before.payment["reference"].to_s == reference.to_s
              raise Core::Conflict.new(
                "order payment is already confirmed with a different reference",
                code: "payment_reference_mismatch",
                details: { order_id: before.id }
              )
            end
            return OrderResult.new(order: before, reservation: reservation)
          end

          evidence = Core::RecordSupport.document(data, field: "payment data").merge(
            "provider" => provider.to_s,
            "amount" => Integer(amount).to_s,
            "currency" => currency.to_s.upcase
          )
          confirm_payment_record(
            before,
            reference: reference,
            data: evidence,
            reservation: reservation
          )
        rescue ArgumentError, TypeError
          raise ArgumentError, "payment amount must be a positive integer"
        end

        def confirm_payment(order_id:, reference:, data: {}, settlement: nil)
          before = @kernel.find_order(order_id)
          ensure_payment_required!(before)

          if settlement
            @kernel.verify_settlement(settlement)
          elsif @settlement_provider && before.payment["settlement_required"]
            @kernel.verify_settlement(@settlement_provider.find_by_order(order_id))
          end

          reservation = @listings.reservation_for_order(order_id) ||
                        raise(Core::NotFound.new("marketplace_order", order_id))
          confirm_payment_record(
            before,
            reference: reference,
            data: data,
            reservation: reservation
          )
        end

        def find_order(customer_user_id:, order_id:)
          customer_id = normalized_customer_id(customer_user_id)
          reservation = @listings.reservation_for_order(order_id) ||
                        raise(Core::NotFound.new("marketplace_order", order_id))
          ensure_owner!(reservation, customer_id)
          order = @kernel.find_order(order_id)
          order = @kernel.cancel_order(order.id) if reservation.status == "released" && order.status == "payment_pending"
          OrderResult.new(order: order, reservation: reservation)
        end

        def execute_order(customer_user_id:, order_id:)
          current = find_order(customer_user_id: customer_user_id, order_id: order_id)
          unless current.reservation.status == "committed" && payment_satisfied?(current.order)
            raise Core::Conflict.new(
              "payment confirmation is required before fulfillment",
              code: "payment_required",
              details: { order_id: current.order.id }
            )
          end

          OrderResult.new(
            order: @kernel.execute_order(current.order.id),
            reservation: current.reservation
          )
        end

        def release_quote(customer_user_id:, quote_id:)
          customer_id = normalized_customer_id(customer_user_id)
          reservation = @listings.release(
            customer_user_id: customer_id,
            quote_id: quote_id
          )
          if reservation.order_id
            order = @kernel.find_order(reservation.order_id)
            @kernel.cancel_order(order.id) if order.status == "payment_pending"
          end
          reservation
        end

        private

        def confirm_payment_record(before, reference:, data:, reservation:)
          confirmed = @kernel.confirm_order_payment(
            before.id,
            reference: reference,
            data: data
          )
          begin
            committed = @listings.commit_payment(order_id: before.id)
          rescue StandardError => error
            rollback_confirmed_payment(before, confirmed)
            expire_failed_payment(before.id, error)
            raise
          end

          OrderResult.new(
            order: @kernel.execute_order(before.id),
            reservation: committed
          )
        end

        def ensure_payment_required!(order)
          return if order.payment

          raise Core::Conflict.new(
            "order does not require marketplace payment confirmation",
            code: "payment_not_required",
            details: { order_id: order.id }
          )
        end

        def validate_provider_payment!(order, provider:, amount:, currency:)
          expected = order.payment["provider"]
          unless expected.is_a?(Hash)
            raise Core::Conflict.new(
              "order is not configured for provider payment",
              code: "payment_provider_not_configured",
              details: { order_id: order.id }
            )
          end

          received_amount = Integer(amount)
          raise ArgumentError unless received_amount.positive?
          expected_amount = Integer(expected.fetch("amount"))
          received_provider = provider.to_s
          received_currency = currency.to_s.upcase

          return if received_provider == expected.fetch("provider") &&
                    received_currency == expected.fetch("currency") &&
                    received_amount == expected_amount

          raise Core::Conflict.new(
            "provider payment does not match the order",
            code: "payment_provider_mismatch",
            details: {
              order_id: order.id,
              expected_provider: expected.fetch("provider"),
              expected_currency: expected.fetch("currency"),
              expected_amount: expected_amount.to_s
            }
          )
        end

        def enforce_purchase_quantity!(product, quantity)
          return unless product.metadata.dig("purchase", "quantity_mode") == "single"
          return if quantity == BigDecimal("1")

          raise Core::Conflict.new(
            "product can only be purchased one at a time",
            code: "single_quantity_only",
            details: { sku: product.sku, quantity: quantity.to_s("F") }
          )
        end

        def resolve_recipient(product, customer_id, recipient)
          policy = product.metadata.dig("purchase", "recipient")
          return nil unless policy
          unless @recipient_resolver
            raise Core::ProviderContractError.new("recipient resolver is required for this product")
          end

          @recipient_resolver.resolve(
            product: product,
            actor_user_id: customer_id,
            recipient: recipient
          )
        end

        def rollback_confirmed_payment(before, confirmed)
          return unless before&.status == "payment_pending" && confirmed&.status == "accepted"

          @kernel.rollback_order_payment(confirmed.id)
        rescue StandardError
          nil
        end

        def expire_failed_payment(order_id, error)
          return unless error.respond_to?(:code) && error.code == "payment_expired"

          order = @kernel.find_order(order_id)
          @kernel.cancel_order(order.id) if order.status == "payment_pending"
        rescue StandardError
          nil
        end

        def payment_satisfied?(order)
          order.payment.nil? || order.payment["status"] == "confirmed"
        end

        def normalized_customer_id(value)
          Core::RecordSupport.identifier(value.to_s, field: "customer user id")
        end

        def ensure_owner!(reservation, customer_id)
          return if reservation.customer_user_id == customer_id

          raise Core::Forbidden.new(
            "marketplace order belongs to another user",
            details: { order_id: reservation.order_id }
          )
        end

        def quantity_value(value)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          maximum = BigDecimal("1e16")
          unless number.finite? && number.positive? && number < maximum && number.round(12) == number
            raise ArgumentError, "quantity must be a positive decimal with at most 12 fractional digits"
          end

          number
        rescue ArgumentError
          raise ArgumentError, "quantity must be a positive decimal with at most 12 fractional digits"
        end

        def stringify_keys(document)
          document.each_with_object({}) { |(key, value), copy| copy[key.to_s] = value }
        end
      end
    end
  end
end
