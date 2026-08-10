# frozen_string_literal: true

require "bigdecimal"
require "digest"
require "securerandom"
require "time"
require_relative "earning"
require_relative "payout_records"

module ZeroXDA
  module Market
    module BrokerEarnings
      Balance = Struct.new(:pending, :available, :payout_queued, :paid, :currency, keyword_init: true)

      class Service
        def initialize(store:, localization:, clock: -> { Time.now.utc }, id_generator: SecureRandom.method(:uuid))
          @store = store
          @localization = localization
          @clock = clock
          @id_generator = id_generator
        end

        # Broker-first invariant: the listing ask is what the broker earns.
        # Marketplace fees, settlement costs and client pricing never reduce it.
        def record(order:, reservation:, listing:)
          existing = @store.find_by_order(order.id)
          return existing if existing

          payable = amount_usdt(reservation.supply_unit_price, reservation.supply_currency) * reservation.quantity
          now = current_time
          earning = Earning.new(
            id: @id_generator.call.to_s,
            order_id: order.id,
            reservation_id: reservation.id,
            listing_id: listing.id,
            seller_user_id: listing.seller_user_id,
            quantity: reservation.quantity,
            ask_amount: reservation.supply_unit_price,
            ask_currency: reservation.supply_currency,
            payable_amount: payable.round(12),
            payable_currency: "USDT",
            created_at: now
          )
          @store.transaction { |store| store.insert(earning) }
        end

        # Fulfillment makes an earning economically earned, but a payment rail
        # may expose funds to the market only after a provider maturity window.
        # Once a maturity boundary is recorded it is monotonic: a later call may
        # extend it, but can never make the earning payout-eligible earlier.
        def make_available(order_id:, not_before: nil)
          @store.transaction do |store|
            current = store.find_by_order(order_id) || raise(Core::NotFound.new("broker_earning", order_id))
            next current if %w[available payout_queued paid].include?(current.state)
            raise Core::Conflict.new("broker earning is not pending", code: "earning_not_pending") unless current.state == "pending"

            now = current_time
            requested = not_before && normalized_time(not_before, field: "not_before")
            threshold = [current.available_at, requested].compact.max
            if threshold && threshold > now
              next current if current.available_at == threshold

              next store.replace(
                Earning.new(**current.to_h.merge(
                  available_at: threshold,
                  updated_at: now,
                  version: current.version + 1
                )),
                expected_version: current.version
              )
            end

            store.replace(
              Earning.new(**current.to_h.merge(
                state: "available",
                available_at: threshold || now,
                updated_at: now,
                version: current.version + 1
              )),
              expected_version: current.version
            )
          end
        end

        def list(actor_user_id:)
          release_matured(actor_user_id)
          @store.list_by_seller(actor_user_id)
        end

        def balance(actor_user_id:)
          release_matured(actor_user_id)
          groups = @store.list_by_seller(actor_user_id).group_by(&:state)
          sum = ->(state) { (groups[state] || []).sum(BigDecimal("0"), &:payable_amount) }
          Balance.new(pending: sum.call("pending"), available: sum.call("available"),
                      payout_queued: sum.call("payout_queued"), paid: sum.call("paid"), currency: "USDT").freeze
        end

        def payout_profile(actor_user_id:)
          @store.payout_profile(actor_user_id)
        end

        def save_payout_profile(actor_user_id:, network:, destination:, minimum_payout_amount: "0", enabled: true,
                                expected_version: nil)
          @store.transaction do |store|
            current = store.payout_profile(actor_user_id, for_update: true)
            if current
              raise ArgumentError, "version is required" if expected_version.nil?
              version = Integer(expected_version)
              unless version == current.version
                raise Core::ConcurrencyConflict.new("broker_payout_profile", actor_user_id)
              end
            elsif !expected_version.nil?
              raise ArgumentError, "version must be omitted for a new payout profile"
            end

            now = current_time
            profile = PayoutProfile.new(
              seller_user_id: actor_user_id,
              currency: "USDT",
              network: network,
              destination: destination,
              minimum_payout_amount: minimum_payout_amount,
              enabled: enabled,
              created_at: current&.created_at || now,
              updated_at: now,
              version: current ? current.version + 1 : 0
            )
            store.save_payout_profile(profile, expected_version: current&.version)
          end
        end

        # At most one payout may be in flight for a broker. The payout profile row
        # is locked first, serializing queue requests for that seller. Retrying
        # while a payout is queued/processing returns the same payout and never
        # reassigns newly available earnings into an older amount snapshot.
        def queue_payout(actor_user_id:)
          release_matured(actor_user_id)
          @store.transaction do |store|
            profile = store.payout_profile(actor_user_id, for_update: true)
            unless profile&.enabled
              raise Core::Conflict.new("enabled payout profile is required", code: "payout_profile_required")
            end

            active = store.active_payout(actor_user_id, for_update: true)
            next active if active

            earnings = store.available_by_seller(actor_user_id, for_update: true)
            amount = earnings.sum(BigDecimal("0"), &:payable_amount)
            if amount <= 0
              raise Core::Conflict.new("no available broker earnings", code: "no_available_earnings")
            end
            if amount < profile.minimum_payout_amount
              raise Core::Conflict.new(
                "available balance is below payout threshold",
                code: "payout_threshold_not_met",
                details: { available: amount.to_s("F"), minimum: profile.minimum_payout_amount.to_s("F") }
              )
            end

            now = current_time
            payout = Payout.new(
              id: @id_generator.call.to_s,
              seller_user_id: actor_user_id,
              currency: "USDT",
              network: profile.network,
              destination: profile.destination,
              amount: amount.round(12),
              state: "queued",
              idempotency_key: payout_identity(actor_user_id, earnings),
              provider_data: {},
              created_at: now
            )
            store.insert_payout(payout)

            earnings.each do |earning|
              store.replace(
                Earning.new(**earning.to_h.merge(
                  state: "payout_queued",
                  payout_id: payout.id,
                  updated_at: now,
                  version: earning.version + 1
                )),
                expected_version: earning.version
              )
            end
            payout
          end
        end

        def list_payouts(actor_user_id:)
          @store.list_payouts(actor_user_id)
        end

        def confirm_payout(payout_id:, external_reference:, provider_data: {})
          reference = external_reference.to_s.strip
          raise ArgumentError, "external reference is required" if reference.empty?

          @store.transaction do |store|
            current = store.find_payout(payout_id, for_update: true) || raise(Core::NotFound.new("broker_payout", payout_id))
            if current.state == "paid"
              if current.external_reference == reference
                next current
              end
              raise Core::Conflict.new("paid payout reference cannot be changed", code: "payout_already_paid")
            end
            unless %w[queued processing].include?(current.state)
              raise Core::Conflict.new("payout is not confirmable", code: "payout_not_confirmable")
            end

            duplicate = store.find_payout_by_external_reference(network: current.network, external_reference: reference)
            if duplicate && duplicate.id != current.id
              raise Core::Conflict.new("external payout reference is already used", code: "duplicate_payout_reference")
            end

            earnings = store.list_by_payout(current.id, for_update: true)
            validate_payout_earnings!(current, earnings)

            now = current_time
            paid = Payout.new(**current.to_h.merge(
              state: "paid",
              external_reference: reference,
              provider_data: provider_data,
              paid_at: now,
              updated_at: now,
              version: current.version + 1
            ))
            store.replace_payout(paid, expected_version: current.version)

            earnings.each do |earning|
              store.replace(
                Earning.new(**earning.to_h.merge(
                  state: "paid",
                  paid_at: now,
                  updated_at: now,
                  version: earning.version + 1
                )),
                expected_version: earning.version
              )
            end
            paid
          end
        end

        private

        def release_matured(actor_user_id)
          now = current_time
          @store.transaction do |store|
            store.list_by_seller(actor_user_id).each do |earning|
              next unless earning.state == "pending" && earning.available_at && earning.available_at <= now

              store.replace(
                Earning.new(**earning.to_h.merge(
                  state: "available",
                  updated_at: now,
                  version: earning.version + 1
                )),
                expected_version: earning.version
              )
            end
          end
        end

        def payout_identity(actor_user_id, earnings)
          earning_ids = earnings.map(&:id).sort
          fingerprint = Digest::SHA256.hexdigest(earning_ids.join("\0"))
          "broker/#{actor_user_id}/#{fingerprint}"
        end

        def validate_payout_earnings!(payout, earnings)
          invalid = earnings.empty? || earnings.any? do |earning|
            earning.seller_user_id != payout.seller_user_id ||
              earning.state != "payout_queued" ||
              earning.payout_id != payout.id ||
              earning.payable_currency != payout.currency
          end
          total = earnings.sum(BigDecimal("0"), &:payable_amount)
          invalid ||= total.round(12) != payout.amount
          return unless invalid

          raise Core::Conflict.new(
            "payout ledger does not match its attached earnings",
            code: "payout_integrity_mismatch",
            details: { payout_id: payout.id }
          )
        end

        def amount_usdt(amount, currency)
          return BigDecimal(amount.to_s) if currency == "USDT"
          @localization.amount_usdt(amount: amount, currency: currency)
        end

        def normalized_time(value, field:)
          return value.utc if value.is_a?(Time)

          Time.iso8601(value.to_s).utc
        rescue ArgumentError
          raise ArgumentError, "#{field} must be an ISO 8601 time"
        end

        def current_time
          value = @clock.call
          value.is_a?(Time) ? value.utc : Time.parse(value.to_s).utc
        end
      end
    end
  end
end
