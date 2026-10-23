ENV["RACK_ENV"] = "test"

require "minitest/autorun"
require "rack/test"
require "tmpdir"
require_relative "../app"

module WebhookTestHelpers
  include Rack::Test::Methods

  API_KEY = WebhookAPIReference.settings.api_key

  def app
    WebhookAPIReference
  end

  # every test starts with no events processed
  def before_setup
    super
    WebhookAPIReference.settings.processed_events.clear
  end

  # POSTs body to the endpoint, signed the way VMI signs it. Pass headers to
  # override or (with nil) drop any of the defaults.
  def post_event(body, headers: {}, key: API_KEY, timestamp: Time.now.to_i.to_s)
    body = body.to_json unless body.is_a?(String)
    defaults = {
      "CONTENT_TYPE" => "application/json",
      "HTTP_X_VMI_TIMESTAMP" => timestamp,
      "HTTP_X_VMI_SIGNATURE" => SignatureVerifier.generate(body, timestamp, key),
      "HTTP_X_VMI_CONFIRMATION_CODE" => "CONF0001"
    }
    # dup: Rack re-encodes the body in place, which warns on string literals
    post "/api/v1/income-report", body.dup, defaults.merge(headers).compact
  end

  def json_response
    JSON.parse(last_response.body)
  end

  def error_fields
    json_response.fetch("errors", []).map { |e| e["field"] }
  end

  def report_submission(event_type: nil, confirmation_code: "CONF0001")
    payload = {
      "report_metadata" => {
        "confirmation_code" => confirmation_code,
        "filenames" => { "sftp" => "inbox/VMI_00012345_20260513_ConfCONF0001.pdf" },
        "report_date_range" => { "start_date" => "2025-11-01", "end_date" => "2026-02-01" },
        "consent_timestamp_utc" => "2026-02-01T10:30:00Z"
      },
      "client_information" => { "case_number" => "ABC1234" },
      "employment_records" => []
    }
    event_type ? { "event_type" => event_type }.merge(payload) : payload
  end

  def transmission_complete(**overrides)
    {
      "event_type" => "TransmissionComplete",
      "confirmation_code" => "CONF0001",
      "transmission_method" => "sftp",
      "uri" => "inbox/VMI_00012345_20260513_ConfCONF0001.pdf",
      "completed_at" => "2026-05-13T18:04:11Z"
    }.merge(overrides.transform_keys(&:to_s))
  end
end
