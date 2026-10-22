require_relative "test_helper"

class TransmissionCompleteValidatorTest < Minitest::Test
  include WebhookTestHelpers

  def errors_for(payload)
    TransmissionCompleteValidator.new(payload).validate.map { |e| e[:field] }
  end

  def test_valid_event
    assert_empty errors_for(transmission_complete)
  end

  def test_uri_may_be_null_for_methods_without_a_file
    assert_empty errors_for(transmission_complete(transmission_method: "shared_email", uri: nil))
  end

  def test_uri_key_is_required
    payload = transmission_complete
    payload.delete("uri")
    assert_equal ["uri"], errors_for(payload)
  end

  def test_uri_must_be_a_string
    assert_equal ["uri"], errors_for(transmission_complete(uri: 5))
  end

  def test_unrecognized_transmission_methods_are_accepted
    assert_empty errors_for(transmission_complete(transmission_method: "carrier_pigeon"))
  end

  def test_required_strings
    %w[confirmation_code transmission_method].each do |field|
      assert_equal [field], errors_for(transmission_complete(field => nil)), "#{field} nil"
      assert_equal [field], errors_for(transmission_complete(field => "  ")), "#{field} blank"
    end
  end

  def test_completed_at_format
    assert_equal ["completed_at"], errors_for(transmission_complete(completed_at: nil))
    assert_equal ["completed_at"], errors_for(transmission_complete(completed_at: "2026-05-13 18:04:11"))
  end
end
