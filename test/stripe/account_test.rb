require File.expand_path('../../test_helper', __FILE__)

module Stripe
  class AccountTest < Test::Unit::TestCase

    should "account should be retrievable" do
      a = Stripe::Account.retrieve
      assert_true a.email.is_a?(String)
      assert_true [false, true].include?(a.charge_enabled)
      assert_true [false, true].include?(a.details_submitted)
    end

  end
end