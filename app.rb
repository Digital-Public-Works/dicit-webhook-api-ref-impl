require "sinatra/base"
require "json"
require "openssl"
require_relative "lib/income_report_validator"
require_relative "lib/transmission_complete_validator"
require_relative "lib/signature_verifier"

class WebhookAPIReference < Sinatra::Base
  REPORT_SUBMISSION = "ReportSubmission".freeze
  TRANSMISSION_COMPLETE = "TransmissionComplete".freeze

  configure do
    # the shared secret agreed with VMI; used to verify X-VMI-Signature on every request
    set :api_key, ENV.fetch("VMI_API_KEY", "abc123_example_key")
    set :logging, true
  end

  # basic swagger config path
  get "/" do
    redirect "/swagger.html"
  end

  # sinatra dev server code, not necessary in actual implementation
  before "/api/*" do
    content_type :json
    @raw_body = request.body.read rescue ""

    logger.info "=== Incoming Request ==="
    logger.info "#{request.request_method} #{request.path_info} from #{request.ip}"
    logger.info "Headers: X-VMI-Timestamp=#{request.env['HTTP_X_VMI_TIMESTAMP'] || '[MISSING]'} " \
                "X-VMI-Signature=#{request.env['HTTP_X_VMI_SIGNATURE'] ? '[PRESENT]' : '[MISSING]'} " \
                "X-VMI-Confirmation-Code=#{request.env['HTTP_X_VMI_CONFIRMATION_CODE'] || '[MISSING]'} " \
                "X-VMI-API-Key=#{request.env['HTTP_X_VMI_API_KEY'] ? '[PRESENT, ignored]' : '[ABSENT]'} " \
                "Content-Type=#{request.content_type || '[MISSING]'}"
  end

  # reference implementation of the endpoint that will need to be created.
  # It accepts both webhook contract versions, so a partner can deploy it before
  # VMI switches them from contract 1 to contract 2:
  #   - contract 1 (legacy): the body is the bare income report (no event_type)
  #     and VMI also sends X-VMI-API-Key, which is ignored here.
  #   - contract 2: the body has a top-level event_type (ReportSubmission or
  #     TransmissionComplete) and the API key is never sent.
  # Both are authenticated the same way: by verifying X-VMI-Signature.
  post "/api/v1/income-report" do

    # ensure expected headers are present
    header_errors = validate_headers(request)
    unless header_errors.empty?
      halt 401, error_response("AUTHENTICATION_ERROR", "Missing or invalid required headers.", header_errors)
    end

    body = @raw_body

    # verify signature.
    timestamp = request.env["HTTP_X_VMI_TIMESTAMP"]
    signature = request.env["HTTP_X_VMI_SIGNATURE"]
    unless SignatureVerifier.verify(body, timestamp, signature, settings.api_key)
      logger.warn "Signature verification failed for timestamp=#{timestamp}"
      halt 401, error_response("AUTHENTICATION_ERROR", "Signature verification failed.")
    end

    # basic validation that the body is in fact valid JSON
    begin
      payload = JSON.parse(body)
    rescue JSON::ParserError => e
      halt 400, error_response("PARSE_ERROR", "Request body is not valid JSON.", [
        { field: "body", reason: e.message }
      ])
    end

    unless payload.is_a?(Hash)
      halt 400, error_response("VALIDATION_ERROR", "The request was well-formed but contains errors.", [
        { field: "body", reason: "Must be a JSON object." }
      ])
    end

    event_type = payload["event_type"]
    unless event_type.nil? || event_type.is_a?(String)
      halt 400, error_response("VALIDATION_ERROR", "The request was well-formed but contains errors.", [
        { field: "event_type", reason: "Must be a string." }
      ])
    end

    case event_type
    when nil, REPORT_SUBMISSION
      # no event_type means a contract 1 (legacy) request, which is always a report submission
      receive_report_submission(payload)
    when TRANSMISSION_COMPLETE
      receive_transmission_complete(payload)
    else
      # accept and ignore event types this receiver doesn't know yet, so new
      # VMI events don't cause failed (and retried) deliveries
      logger.info "Ignoring unrecognized event_type=#{event_type}"
      status 200
      {
        status: "ignored",
        message: "Unrecognized event_type '#{event_type}' was ignored."
      }.to_json
    end
  end

  not_found do
    error_response("NOT_FOUND", "The requested endpoint does not exist.")
  end

  error 405 do
    error_response("METHOD_NOT_ALLOWED", "Only POST is accepted for this endpoint.")
  end

  private

  def receive_report_submission(payload)
    # validate the payload
    validator = IncomeReportValidator.new(payload)
    validation_errors = validator.validate

    # exit out if the incoming payload is not in the expected structure
    halt_on_validation_errors(validation_errors)

    # TODO: Insert your processing of this payload here

    save_payload(payload, request.env["HTTP_X_VMI_CONFIRMATION_CODE"] || "unknown")

    confirmation_code = payload.dig("report_metadata", "confirmation_code")
    record_count = payload.dig("employment_records")&.size || 0
    date_range_start = payload.dig("report_metadata", "report_date_range", "start_date")
    date_range_end = payload.dig("report_metadata", "report_date_range", "end_date")
    consent_ts = payload.dig("report_metadata", "consent_timestamp_utc")
    filenames = payload.dig("report_metadata", "filenames")
    logger.info "Report submission accepted: event_type=#{payload['event_type'] || '[NONE, contract 1]'} " \
                "confirmation_code=#{confirmation_code} " \
                "employment_records=#{record_count} " \
                "date_range=#{date_range_start}..#{date_range_end} " \
                "consent_timestamp=#{consent_ts} " \
                "filenames=#{filenames.is_a?(Hash) ? filenames.inspect : '[NONE]'}"

    # success! Let VMI know that it all worked
    status 200
    {
      status: "success",
      message: "Income report received successfully.",
      confirmation_code: confirmation_code
    }.to_json
  end

  def receive_transmission_complete(payload)
    validation_errors = TransmissionCompleteValidator.new(payload).validate
    halt_on_validation_errors(validation_errors)

    # TODO: Insert your processing of this event here, e.g. fetch the file at
    # `uri` from the SFTP server or S3 bucket now that it has been delivered.
    # Events can arrive before the matching ReportSubmission and may be
    # delivered more than once, so correlate on confirmation_code and make this
    # processing idempotent.

    confirmation_code = payload["confirmation_code"]
    transmission_method = payload["transmission_method"]
    save_payload(payload, "#{confirmation_code}_#{TRANSMISSION_COMPLETE}_#{transmission_method}")

    logger.info "Transmission complete accepted: confirmation_code=#{confirmation_code} " \
                "transmission_method=#{transmission_method} " \
                "uri=#{payload['uri'] || '[NONE]'} " \
                "completed_at=#{payload['completed_at']}"

    status 200
    {
      status: "success",
      message: "Transmission complete event received successfully.",
      confirmation_code: confirmation_code
    }.to_json
  end

  def halt_on_validation_errors(validation_errors)
    return if validation_errors.empty?

    logger.warn "Validation failed: #{validation_errors.map { |e| "#{e[:field]}: #{e[:reason]}" }.join(', ')}"
    halt 400, error_response("VALIDATION_ERROR", "The request was well-formed but contains errors.", validation_errors)
  end

  # Dump received payload to disk for validation/debugging
  def save_payload(payload, name)
    payload_dir = ENV["PAYLOAD_DIR"]
    return unless payload_dir

    require "fileutils"
    FileUtils.mkdir_p(payload_dir)

    timestamp = Time.now.strftime("%Y%m%dT%H%M%S")
    filename = "#{timestamp}_#{name}.json"

    File.write(File.join(payload_dir, filename), JSON.pretty_generate(payload))
    logger.info "Saved payload to #{payload_dir}/#{filename}"
  end

  def error_response(error_code, message, errors = nil)
    response = { error_code: error_code, message: message }
    response[:errors] = errors if errors
    response.to_json
  end

  # X-VMI-API-Key is deliberately not required: VMI stops sending it under
  # contract 2, and it is ignored when present under contract 1.
  def validate_headers(request)
    errors = []

    {
      "HTTP_X_VMI_TIMESTAMP" => "X-VMI-Timestamp",
      "HTTP_X_VMI_SIGNATURE" => "X-VMI-Signature",
      "HTTP_X_VMI_CONFIRMATION_CODE" => "X-VMI-Confirmation-Code"
    }.each do |env_key, header_name|
      value = request.env[env_key]
      if value.nil? || value.strip.empty?
        errors << { field: header_name, reason: "Header '#{header_name}' is required." }
      end
    end

    unless request.content_type&.start_with?("application/json")
      errors << { field: "Content-Type", reason: "Content-Type must be 'application/json'." }
    end

    timestamp = request.env["HTTP_X_VMI_TIMESTAMP"]
    if timestamp && !timestamp.strip.empty? && !timestamp.match?(/\A\d+\z/)
      errors << { field: "X-VMI-Timestamp", reason: "Must be seconds since Unix epoch (numeric)." }
    end

    errors
  end
end
