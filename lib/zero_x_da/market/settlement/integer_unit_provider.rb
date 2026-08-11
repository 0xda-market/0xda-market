# frozen_string_literal: true

require "time"
require_relative "../core/contracts"
require_relative "../payments/fixed_rate_integer_terms"
require_relative "contracts"
require_relative "record"
require_relative "memory_store"

module ZeroXDA
  module Market
    module Settlement
      # Generic settlement provider for payment rails whose customer-facing
      # amount is an integer number of provider units while the marketplace
      # remains economically canonical in USDT.
      class IntegerUnitProvider
        attr_reader :key, :default_cost, :funds_hold_seconds

        def initialize(
          key:, currency:, usdt_per_unit:, clock:, store: MemoryStore.new,
          allowed_skus: nil, variable_fee_bps: 0, fixed_cost_usdt: 0,
          funds_hold_seconds: 0
        )
          @key = Core::RecordSupport.identifier(key.to_s, field: "settlement provider key")
          @currency = Core::RecordSupport.identifier(currency.to_s.upcase, field: "settlement currency")
          @clock = clock
          @store = store
          @funds_hold_seconds = Integer(funds_hold_seconds)
          raise ArgumentError, "funds_hold_seconds must be non-negative" if @funds_hold_seconds.negative?
          @terms = Payments::FixedRateIntegerTerms.new(
            provider_key: @key,
            currency: @currency,
            usdt_per_unit: usdt_per_unit,
            allowed_skus: allowed_skus
          )
          @default_cost = Core::Contracts::CostResult.new(
            variable_fee_bps: variable_fee_bps,
            fixed_cost_usdt: fixed_cost_usdt
          )
        rescue ArgumentError, TypeError
          raise ArgumentError, "funds_hold_seconds must be a non-negative integer" if !defined?(@funds_hold_seconds) || @funds_hold_seconds.nil?
          raise
        end

        def cost(quote:)
          raise ArgumentError, "quote is required" unless quote

          @default_cost
        end

        # Called before the order exists so the exact provider amount can be
        # snapshotted into the immutable payment projection.
        def quote(amount_usdt:, sku: nil)
          @terms.quote(amount_usdt: amount_usdt, sku: sku)
        end

        def charge(order:, idempotency_key:)
          payment = order.payment || raise(Core::ProviderContractError.new("settlement requires an order payment document"))
          unless payment.fetch("currency").to_s.upcase == "USDT"
            raise Core::ProviderContractError.new("integer-unit settlement requires canonical USDT order payment")
          end
          terms = payment.fetch("provider")
          validate_terms!(terms, payment.fetch("amount"))

          existing = @store.find_by_order(order.id)
          return result_for(existing) if existing

          now = current_time
          record = Record.new(
            id: "settlement:#{order.id}",
            order_id: order.id,
            provider_key: @key,
            expected_usdt: payment.fetch("amount"),
            currency: @currency,
            idempotency_key: Core::RecordSupport.identifier(idempotency_key.to_s, field: "idempotency key"),
            provider_data: {
              "payment_terms" => terms
            },
            expires_at: payment["expires_at"] && Time.iso8601(payment.fetch("expires_at")),
            created_at: now
          )
          @store.insert(record)
          append_event(record)
          result_for(record)
        rescue Core::Conflict => error
          raise unless error.code == "duplicate_record"

          result_for(@store.find_by_order(order.id) || raise)
        end

        def verify(settlement:)
          result_for(@store.fetch(settlement.id))
        end

        def find_by_order(order_id)
          @store.find_by_order(order_id)
        end

        def funds_available_at(order_id:)
          settlement = @store.find_by_order(order_id) || raise(Core::NotFound.new("settlement", order_id))
          return nil unless settlement.settled?

          value = settlement.provider_data["funds_available_at"]
          value && Time.iso8601(value)
        end

        # Trusted adapter action after an authoritative provider-side payment
        # event. It is intentionally not browser-callable without the channel
        # adapter's server credential.
        def confirm(order_id:, reference:, provider:, amount:, currency:, data: {})
          payment_reference = Core::RecordSupport.identifier(reference.to_s, field: "settlement reference")
          payment_data = Core::RecordSupport.document(data, field: "settlement provider data")
          received_amount = Integer(amount)
          raise ArgumentError, "settlement amount must be a positive integer" unless received_amount.positive?

          @store.transaction do |store|
            current = store.find_by_order(order_id) || raise(Core::NotFound.new("settlement", order_id))
            if current.settled?
              if current.external_reference == payment_reference
                next current
              end
              raise Core::Conflict.new(
                "settlement is already confirmed with a different reference",
                code: "payment_reference_mismatch",
                details: { order_id: order_id.to_s }
              )
            end
            unless current.pending?
              raise Core::InvalidTransition.new(
                resource: "settlement",
                id: current.id,
                from: current.state,
                event: "confirm"
              )
            end

            now = current_time
            if current.expired?(at: now)
              expired = rebuild(current, state: "expired", updated_at: now)
              store.replace(expired, expected_version: current.version)
              append_event(expired, store: store)
              raise Core::Conflict.new(
                "settlement has expired",
                code: "payment_expired",
                details: { order_id: order_id.to_s }
              )
            end

            terms = current.provider_data.fetch("payment_terms")
            validate_provider_evidence!(
              terms,
              provider: provider,
              amount: received_amount,
              currency: currency
            )
            received_usdt = BigDecimal(received_amount.to_s) * @terms.usdt_per_unit
            if received_usdt < current.expected_usdt
              raise Core::Conflict.new(
                "settlement value is below the expected market amount",
                code: "settlement_amount_mismatch",
                details: { settlement_id: current.id }
              )
            end

            funds_available_at = now + @funds_hold_seconds
            settled = rebuild(
              current,
              state: "settled",
              received_usdt: received_usdt,
              external_reference: payment_reference,
              provider_data: current.provider_data.merge(
                "confirmation" => payment_data,
                "funds_available_at" => funds_available_at.iso8601(6),
                "funds_hold_seconds" => @funds_hold_seconds
              ),
              updated_at: now
            )
            store.replace(settled, expected_version: current.version)
            append_event(settled, store: store)
            settled
          end
        rescue TypeError
          raise ArgumentError, "settlement amount must be a positive integer"
        end

        private

        def validate_terms!(terms, expected_usdt)
          unless terms.is_a?(Hash) &&
                 terms["provider"] == @key &&
                 terms["currency"] == @currency &&
                 Integer(terms.fetch("amount")).positive? &&
                 BigDecimal(terms.dig("valuation", "amount_usdt").to_s) == BigDecimal(expected_usdt.to_s)
            raise Core::ProviderContractError.new("order payment provider terms are invalid")
          end
        rescue KeyError, ArgumentError, TypeError
          raise Core::ProviderContractError.new("order payment provider terms are invalid")
        end

        def validate_provider_evidence!(terms, provider:, amount:, currency:)
          return if provider.to_s == terms.fetch("provider") &&
                    currency.to_s.upcase == terms.fetch("currency") &&
                    amount == Integer(terms.fetch("amount"))

          raise Core::Conflict.new(
            "provider payment does not match the settlement",
            code: "payment_provider_mismatch",
            details: {
              expected_provider: terms.fetch("provider"),
              expected_currency: terms.fetch("currency"),
              expected_amount: terms.fetch("amount").to_s
            }
          )
        rescue KeyError, ArgumentError, TypeError
          raise Core::ProviderContractError.new("settlement payment terms are invalid")
        end

        def result_for(settlement)
          case settlement.state
          when "pending"
            Core::Contracts::PendingSettlement.new(
              settlement: settlement,
              reference: settlement.id,
              data: settlement.provider_data.merge("state" => settlement.state)
            )
          when "settled"
            Core::Contracts::SettlementResult.new(
              settlement: settlement,
              reference: settlement.external_reference,
              data: settlement.provider_data
            )
          when "expired"
            raise Core::Conflict.new(
              "settlement has expired",
              code: "payment_expired",
              details: { settlement_id: settlement.id }
            )
          else
            raise Core::ProviderFailure.new(
              "settlement failed",
              code: "settlement_failed",
              retryable: false,
              details: { settlement_id: settlement.id }
            )
          end
        end

        def rebuild(record, **changes)
          attributes = {
            id: record.id,
            order_id: record.order_id,
            provider_key: record.provider_key,
            state: record.state,
            expected_usdt: record.expected_usdt,
            received_usdt: record.received_usdt,
            currency: record.currency,
            tolerance_bps: record.tolerance_bps,
            idempotency_key: record.idempotency_key,
            external_reference: record.external_reference,
            provider_data: record.provider_data,
            expires_at: record.expires_at,
            created_at: record.created_at,
            updated_at: record.updated_at,
            version: record.version
          }
          Record.new(**attributes.merge(changes, version: record.version + 1))
        end

        def append_event(record, store: @store)
          store.append_event(
            "settlement_id" => record.id,
            "state" => record.state,
            "provider_data" => record.provider_data,
            "observed_at" => record.updated_at.iso8601(6)
          )
        end

        def current_time
          value = @clock.call
          raise Core::ProviderContractError.new("clock must return a Time") unless value.is_a?(Time)

          value.getutc
        end
      end
    end
  end
end
