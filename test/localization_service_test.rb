# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/localization/memory_store"
require "zero_x_da/market/localization/service"

class LocalizationServiceTest < Minitest::Test
  def setup
    @service = ZeroXDA::Market::Localization::Service.new(
      fx_store: ZeroXDA::Market::Localization::MemoryStore.new
    )
  end

  def test_uses_en_us_as_the_default_locale
    locale = @service.resolve(language_code: nil)

    assert_equal "en_US", locale.code
    assert_equal "en", locale.language
  end

  def test_maps_telegram_ukrainian_codes_to_uk_ua
    assert_equal "uk_UA", @service.locale_for("uk")
    assert_equal "uk_UA", @service.locale_for("uk-UA")
  end

  def test_falls_back_to_en_us_for_unsupported_languages
    assert_equal "en_US", @service.locale_for("fr")
  end
end
