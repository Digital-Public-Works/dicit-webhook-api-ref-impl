require_relative "test_helper"

class AuthenticationTest < Minitest::Test
  include WebhookTestHelpers

  def test_accepts_a_correctly_signed_request
    post_event(report_submission)
    assert_equal 200, last_response.status
  end

  def test_rejects_a_signature_made_with_the_wrong_key
    post_event(report_submission, key: "wrong-key")
    assert_equal 401, last_response.status
    assert_equal "AUTHENTICATION_ERROR", json_response["error_code"]
  end

  def test_rejects_a_body_changed_after_signing
    body = report_submission.to_json
    timestamp = Time.now.to_i.to_s
    post_event(body.sub("ABC1234", "XYZ9999"), timestamp: timestamp,
               headers: { "HTTP_X_VMI_SIGNATURE" => SignatureVerifier.generate(body, timestamp, API_KEY) })
    assert_equal 401, last_response.status
  end

  def test_rejects_missing_required_headers
    %w[HTTP_X_VMI_TIMESTAMP HTTP_X_VMI_SIGNATURE HTTP_X_VMI_CONFIRMATION_CODE].each do |header|
      post_event(report_submission, headers: { header => nil })
      assert_equal 401, last_response.status, "expected 401 without #{header}"
    end
  end

  def test_does_not_require_the_api_key_header
    post_event(report_submission(event_type: "ReportSubmission"))
    assert_equal 200, last_response.status
  end

  def test_ignores_the_api_key_header_even_when_wrong
    post_event(report_submission, headers: { "HTTP_X_VMI_API_KEY" => "not-the-key" })
    assert_equal 200, last_response.status
  end

  def test_rejects_a_stale_timestamp
    post_event(report_submission, timestamp: (Time.now.to_i - 301).to_s)
    assert_equal 401, last_response.status
    assert_match(/outside the allowed window/, json_response["message"])
  end

  def test_rejects_a_timestamp_in_the_future
    post_event(report_submission, timestamp: (Time.now.to_i + 301).to_s)
    assert_equal 401, last_response.status
  end

  def test_accepts_a_timestamp_inside_the_window
    post_event(report_submission, timestamp: (Time.now.to_i - 240).to_s)
    assert_equal 200, last_response.status
  end

  def test_timestamp_check_can_be_turned_off
    app.set :timestamp_tolerance, 0
    post_event(report_submission, timestamp: "1000")
    assert_equal 200, last_response.status
  ensure
    app.set :timestamp_tolerance, 300
  end
end

class EventRoutingTest < Minitest::Test
  include WebhookTestHelpers

  def test_contract_1_report_submission_has_no_event_type
    post_event(report_submission, headers: { "HTTP_X_VMI_API_KEY" => API_KEY })
    assert_equal 200, last_response.status
    assert_equal "success", json_response["status"]
    assert_equal "Income report received successfully.", json_response["message"]
  end

  def test_contract_2_report_submission
    post_event(report_submission(event_type: "ReportSubmission"))
    assert_equal 200, last_response.status
    assert_equal "Income report received successfully.", json_response["message"]
  end

  def test_transmission_complete
    post_event(transmission_complete)
    assert_equal 200, last_response.status
    assert_equal "Transmission complete event received successfully.", json_response["message"]
    assert_equal "CONF0001", json_response["confirmation_code"]
  end

  def test_unrecognized_event_type_is_ignored_with_200
    post_event({ "event_type" => "SomethingNew", "anything" => 1 })
    assert_equal 200, last_response.status
    assert_equal "ignored", json_response["status"]
  end

  def test_non_string_event_type_is_rejected
    post_event(report_submission.merge("event_type" => 2))
    assert_equal 400, last_response.status
    assert_equal ["event_type"], error_fields
  end

  def test_non_object_body_is_rejected
    post_event("[1]")
    assert_equal 400, last_response.status
    assert_equal ["body"], error_fields
  end

  def test_invalid_json_is_a_parse_error
    post_event("{not json")
    assert_equal 400, last_response.status
    assert_equal "PARSE_ERROR", json_response["error_code"]
  end
end

class ClientInformationTest < Minitest::Test
  include WebhookTestHelpers

  def test_accepts_a_report_whose_applicant_was_not_asked_about_other_jobs
    payload = report_submission
    payload["client_information"]["additional_jobs_to_report"] = nil
    post_event(payload)
    assert_equal 200, last_response.status
  end
end

class ConfirmationCodeTest < Minitest::Test
  include WebhookTestHelpers

  def test_report_submission_code_must_match_the_header
    post_event(report_submission(confirmation_code: "OTHER"))
    assert_equal 400, last_response.status
    assert_equal ["report_metadata.confirmation_code"], error_fields
  end

  def test_transmission_complete_code_must_match_the_header
    post_event(transmission_complete(confirmation_code: "OTHER"))
    assert_equal 400, last_response.status
    assert_equal ["confirmation_code"], error_fields
  end
end

class SavePayloadTest < Minitest::Test
  include WebhookTestHelpers

  def setup
    @dir = Dir.mktmpdir
    ENV["PAYLOAD_DIR"] = File.join(@dir, "payloads")
  end

  def teardown
    ENV.delete("PAYLOAD_DIR")
    FileUtils.remove_entry(@dir)
  end

  def saved_files
    Dir.glob("**/*", base: @dir).select { |f| File.file?(File.join(@dir, f)) }
  end

  def test_saves_a_report_submission
    post_event(report_submission)
    assert_equal 200, last_response.status
    assert_equal 1, saved_files.size
    assert_match(%r{\Apayloads/\d{8}T\d{6}_CONF0001\.json\z}, saved_files.first)
  end

  def test_saves_a_transmission_complete
    post_event(transmission_complete)
    assert_match(%r{\Apayloads/\d{8}T\d{6}_CONF0001_TransmissionComplete_sftp\.json\z}, saved_files.first)
  end

  def test_keeps_request_values_from_escaping_the_payload_dir
    post_event(transmission_complete(transmission_method: "../../escaped"))
    assert_equal 200, last_response.status
    assert_equal 1, saved_files.size
    assert saved_files.first.start_with?("payloads/"), "saved outside PAYLOAD_DIR: #{saved_files.first}"
    refute_includes File.basename(saved_files.first), "/"
  end
end

class IdempotencyTest < Minitest::Test
  include WebhookTestHelpers

  def test_a_redelivered_report_submission_is_acknowledged_but_not_reprocessed
    post_event(report_submission)
    assert_equal "success", json_response["status"]

    post_event(report_submission)
    assert_equal 200, last_response.status
    assert_equal "duplicate", json_response["status"]
    assert_equal "CONF0001", json_response["confirmation_code"]
  end

  def test_contract_1_and_2_report_submissions_share_a_key
    post_event(report_submission)
    post_event(report_submission(event_type: "ReportSubmission"))
    assert_equal "duplicate", json_response["status"]
  end

  def test_a_redelivered_transmission_complete_is_acknowledged_but_not_reprocessed
    post_event(transmission_complete)
    post_event(transmission_complete)
    assert_equal 200, last_response.status
    assert_equal "duplicate", json_response["status"]
  end

  def test_transmission_completes_are_keyed_by_method
    post_event(transmission_complete(transmission_method: "sftp"))
    post_event(transmission_complete(transmission_method: "encrypted_s3"))
    assert_equal "success", json_response["status"]
  end

  def test_events_of_different_types_do_not_collide
    post_event(report_submission)
    post_event(transmission_complete)
    assert_equal "success", json_response["status"]
  end

  def test_an_invalid_event_is_not_recorded_as_processed
    post_event(transmission_complete(completed_at: "bad"))
    assert_equal 400, last_response.status
    post_event(transmission_complete)
    assert_equal "success", json_response["status"]
  end

  def test_a_duplicate_is_not_saved_again
    Dir.mktmpdir do |dir|
      ENV["PAYLOAD_DIR"] = dir
      2.times { post_event(transmission_complete) }
      assert_equal 1, Dir.children(dir).size
    ensure
      ENV.delete("PAYLOAD_DIR")
    end
  end
end
