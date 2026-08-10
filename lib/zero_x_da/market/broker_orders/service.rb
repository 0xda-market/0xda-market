# frozen_string_literal: true

require "time"
require_relative "../core/contracts"
require_relative "decision"

module ZeroXDA
  module Market
    module BrokerOrders
      Entry = Struct.new(:decision, :order, :reservation, :listing, :earning, :changed, keyword_init: true)

      class Service
        def initialize(store:, kernel:, listings:, provider:, earnings: nil, clock: -> { Time.now.utc })
          @store = store
          @kernel = kernel
          @listings = listings
          @provider = provider
          @earnings = earnings
          @clock = clock
        end

        def request(order:, reservation:)
          context = @listings.broker_order_context_for_reservation(reservation)
          decision = Decision.new(order_id: order.id, reservation_id: reservation.id,
                                  seller_user_id: context.listing.seller_user_id, created_at: current_time)
          persisted = @store.transaction { |store| store.find(order.id) || store.insert(decision) }
          earning = @earnings&.record(order: order, reservation: reservation, listing: context.listing)
          entry(persisted, order: order, context: context, earning: earning, changed: persisted.equal?(decision))
        end

        def list(actor_user_id:)
          actor = @listings.broker_user(actor_user_id: actor_user_id)
          @store.list_by_seller(actor.id).map do |decision|
            context = @listings.broker_order_context(actor_user_id: actor.id, order_id: decision.order_id)
            entry(decision, context: context)
          end
        end

        def accept(actor_user_id:, order_id:, expected_version:)
          context = @listings.broker_order_context(actor_user_id: actor_user_id, order_id: order_id)
          version = normalized_version(expected_version)
          changed = false
          decision = @store.transaction do |store|
            current = store.find(order_id) || raise(Core::NotFound.new("broker_order_decision", order_id))
            ensure_seller!(current, context.listing.seller_user_id)
            next current if %w[accepted completed].include?(current.status)
            raise Core::ConcurrencyConflict.new("broker_order_decision", current.order_id) unless current.version == version
            changed = true
            store.replace(rebuild(current, status: "accepted", accepted_at: current_time,
                                  updated_at: current_time, version: current.version + 1),
                          expected_version: current.version)
          end
          entry(decision, context: context, changed: changed)
        end

        def complete(actor_user_id:, order_id:, expected_version:, reference: nil, data: {})
          context = @listings.broker_order_context(actor_user_id: actor_user_id, order_id: order_id)
          version = normalized_version(expected_version)
          current = @store.find(order_id) || raise(Core::NotFound.new("broker_order_decision", order_id))
          ensure_seller!(current, context.listing.seller_user_id)
          return entry(current, context: context) if current.status == "completed"
          unless current.status == "accepted"
            raise Core::Conflict.new("broker must accept the order before completion",
                                     code: "broker_acceptance_required", details: { order_id: order_id.to_s })
          end
          raise Core::ConcurrencyConflict.new("broker_order_decision", current.order_id) unless current.version == version

          order = @kernel.find_order(order_id)
          unless order.payment&.fetch("status", nil) == "confirmed"
            raise Core::Conflict.new("payment confirmation is required before broker completion",
                                     code: "payment_required", details: { order_id: order_id.to_s })
          end
          task_id = order.progress&.fetch("reference", nil)
          unless task_id
            order = @kernel.execute_order(order.id)
            task_id = order.progress&.fetch("reference", nil)
          end
          raise Core::Conflict.new("fulfillment task is unavailable", code: "fulfillment_not_ready",
                                   details: { order_id: order_id.to_s }) unless task_id

          @provider.claim_task(task_id, assignee: context.listing.seller_user_id)
          @provider.complete_task(task_id,
                                  reference: reference.to_s.empty? ? "broker/#{current.order_id}" : reference.to_s,
                                  data: data)
          order = @kernel.execute_order(order.id)
          unless order.status == "succeeded"
            raise Core::Conflict.new("fulfillment did not complete", code: "fulfillment_incomplete",
                                     details: { order_id: order.id, status: order.status })
          end

          completed = @store.transaction do |store|
            latest = store.find(order_id) || raise(Core::NotFound.new("broker_order_decision", order_id))
            next latest if latest.status == "completed"
            raise Core::ConcurrencyConflict.new("broker_order_decision", latest.order_id) unless latest.version == current.version
            store.replace(rebuild(latest, status: "completed", completed_at: current_time,
                                  updated_at: current_time, version: latest.version + 1),
                          expected_version: latest.version)
          end
          funds_available_at = if @kernel.respond_to?(:settlement_funds_available_at)
                                 @kernel.settlement_funds_available_at(order.id)
                               end
          earning = @earnings&.make_available(order_id: order.id, not_before: funds_available_at)
          entry(completed, order: order, context: context, earning: earning, changed: true)
        end

        def acknowledge_notification(actor_user_id:, order_id:, event:)
          context = @listings.broker_order_context(actor_user_id: actor_user_id, order_id: order_id)
          field = { "broker_order_accepted" => :accepted_notified_at,
                    "broker_order_completed" => :completed_notified_at }.fetch(event.to_s) do
            raise ArgumentError, "notification event is invalid"
          end
          decision = @store.transaction do |store|
            current = store.find(order_id) || raise(Core::NotFound.new("broker_order_decision", order_id))
            ensure_seller!(current, context.listing.seller_user_id)
            next current if current.public_send(field)
            unless current.pending_notification_event == event.to_s
              raise Core::Conflict.new("notification is not pending", code: "notification_not_pending",
                                       details: { order_id: order_id.to_s, event: event.to_s })
            end
            store.replace(rebuild(current, field => current_time), expected_version: current.version)
          end
          entry(decision, context: context)
        end

        private

        def entry(decision, order: nil, context: nil, earning: nil, changed: false)
          context ||= @listings.broker_order_context(actor_user_id: decision.seller_user_id, order_id: decision.order_id)
          earning ||= @earnings&.list(actor_user_id: decision.seller_user_id)&.find { |item| item.order_id == decision.order_id }
          Entry.new(decision: decision, order: order || @kernel.find_order(decision.order_id),
                    reservation: context.reservation, listing: context.listing, earning: earning, changed: changed)
        end

        def ensure_seller!(decision, seller_user_id)
          return if decision.seller_user_id == seller_user_id.to_s
          raise Core::Forbidden.new("broker order belongs to another seller", details: { order_id: decision.order_id })
        end

        def normalized_version(value)
          number = Integer(value)
          raise ArgumentError, "version must be a non-negative integer" if number.negative?
          number
        rescue ArgumentError, TypeError
          raise ArgumentError, "version must be a non-negative integer"
        end

        def rebuild(decision, **changes)
          Decision.new(**decision.to_h.merge(changes))
        end

        def current_time
          value = @clock.call
          value.is_a?(Time) ? value.utc : Time.parse(value.to_s).utc
        end
      end
    end
  end
end
