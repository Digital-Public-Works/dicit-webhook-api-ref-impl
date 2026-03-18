require "sinatra/base"
require "json"
require "openssl"
require_relative "lib/income_report_validator"
require_relative "lib/signature_verifier"

class WebhookAPIReference < Sinatra::Base
  configure do
    # this would need to be set in your environment as an initial validation that the requset is coming from VMI
    set :api_key, ENV.fetch("VMI_API_KEY", "abc123_example_key")
    # feature flag for Sinatra - this will generally be 'false' in dev evironment
    set :verify_signature, ENV.fetch("VERIFY_SIGNATURE", "false") == "true"
  end

  # basic swagger config path
  get "/" do
    redirect "/swagger.html"
  end

  # sinatra dev server code, not necessary in actual implementation
  before "/api/*" do
    content_type :json
    @raw_body = request.body.read rescue ""
  end

  # reference implementation of the endpoint that will need to be created
  post "/api/v1/income-report" do

    # ensure expected headers are present
    header_errors = validate_headers(request)
    unless header_errors.empty?
      halt 401, error_response("AUTHENTICATION_ERROR", "Missing or invalid required headers.", header_errors)
    end

    # ensure api key matches configured key
    unless request.env["HTTP_X_VMI_API_KEY"] == settings.api_key
      halt 401, error_response("AUTHENTICATION_ERROR", "Invalid API key.")
    end

    body = @raw_body

    # verify signature
    if settings.verify_signature
      timestamp = request.env["HTTP_X_VMI_TIMESTAMP"]
      signature = request.env["HTTP_X_VMI_SIGNATURE"]
      unless SignatureVerifier.verify(body, timestamp, signature, settings.api_key)
        halt 401, error_response("AUTHENTICATION_ERROR", "Signature verification failed.")
      end
    end

    # basic validation that the body is in fact valid JSON
    begin
      payload = JSON.parse(body)
    rescue JSON::ParserError => e
      halt 400, error_response("PARSE_ERROR", "Request body is not valid JSON.", [
        { field: "body", reason: e.message }
      ])
    end

    # validate the payload
    validator = IncomeReportValidator.new(payload)
    validation_errors = validator.validate

    # exit out if the incoming payload is not in the expected structure
    unless validation_errors.empty?
      halt 400, error_response("VALIDATION_ERROR", "The request was well-formed but contains errors.", validation_errors)
    end

    # TODO: Insert your processing of this payload here

    # success! Let VMI know that it all worked
    status 200
    {
      status: "success",
      message: "Income report received successfully.",
      confirmation_code: payload.dig("report_metadata", "confirmation_code")
    }.to_json
  end

  not_found do
    error_response("NOT_FOUND", "The requested endpoint does not exist.")
  end

  error 405 do
    error_response("METHOD_NOT_ALLOWED", "Only POST is accepted for this endpoint.")
  end

  private

  def error_response(error_code, message, errors = nil)
    response = { error_code: error_code, message: message }
    response[:errors] = errors if errors
    response.to_json
  end

  def validate_headers(request)
    errors = []

    {
      "HTTP_X_VMI_TIMESTAMP" => "X-VMI-Timestamp",
      "HTTP_X_VMI_SIGNATURE" => "X-VMI-Signature",
      "HTTP_X_VMI_CONFIRMATION_CODE" => "X-VMI-Confirmation-Code",
      "HTTP_X_VMI_API_KEY" => "X-VMI-API-Key"
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
