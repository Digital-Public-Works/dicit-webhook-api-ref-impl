require_relative "income_report_validator"

# example validator class to verify a TransmissionComplete event's structure
class TransmissionCompleteValidator
  DATETIME_REGEX = IncomeReportValidator::DATETIME_REGEX

  def initialize(payload)
    @payload = payload
    @errors = []
  end

  def validate
    validate_required_string("confirmation_code")
    validate_required_string("transmission_method")
    validate_uri
    validate_completed_at
    @errors
  end

  private

  def add_error(field, reason)
    @errors << { field: field, reason: reason }
  end

  def validate_required_string(key)
    if !@payload.key?(key) || @payload[key].nil?
      add_error(key, "This field is required.")
    elsif !@payload[key].is_a?(String) || @payload[key].strip.empty?
      add_error(key, "Must be a non-empty string.")
    end
  end

  # Always present; null for methods that don't produce a file (shared_email, json).
  def validate_uri
    if !@payload.key?("uri")
      add_error("uri", "This field is required (it may be null).")
    elsif !@payload["uri"].nil? && !@payload["uri"].is_a?(String)
      add_error("uri", "Must be a string or null.")
    end
  end

  def validate_completed_at
    value = @payload["completed_at"]
    if value.nil?
      add_error("completed_at", "This field is required.")
    elsif !value.is_a?(String) || !value.match?(DATETIME_REGEX)
      add_error("completed_at", "Must be a datetime in YYYY-MM-DDTHH:MM:SSZ format.")
    end
  end
end
