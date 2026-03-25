# example validator class to verify payload structure
class IncomeReportValidator
  DATE_REGEX = /\A\d{4}-\d{2}-\d{2}\z/
  DATETIME_REGEX = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
  SSN_REGEX = /\AXXX-XX-\d{4}\z/
  YEAR_REGEX = /\A\d{4}\z/

  EMPLOYMENT_TYPES = %w[W2 GIG].freeze
  EMPLOYMENT_STATUSES = %w[EMPLOYED ACTIVE INACTIVE TERMINATED].freeze
  PAY_FREQUENCIES = %w[ANNUALLY BIWEEKLY DAILY HOURLY MONTHLY QUARTERLY SEMIMONTHLY SEMIWEEKLY VARIABLE WEEKLY].freeze
  BASE_COMPENSATION_INTERVALS = %w[HOURLY DAILY WEEKLY BIWEEKLY SEMIMONTHLY MONTHLY ANNUAL SALARY].freeze
  DEDUCTION_TYPES = %w[PRETAX POSTTAX UNKNOWN].freeze

  def initialize(payload)
    @payload = payload
    @errors = []
  end

  def validate
    validate_report_metadata
    validate_client_information
    validate_employment_records
    @errors
  end

  private

  def add_error(field, reason)
    @errors << { field: field, reason: reason }
  end

  # --- Report Metadata ---

  def validate_report_metadata
    meta = @payload["report_metadata"]
    unless meta.is_a?(Hash)
      add_error("report_metadata", "This field is required and must be an object.")
      return
    end

    validate_required_string(meta, "confirmation_code", "report_metadata.confirmation_code")

    range = meta["report_date_range"]
    unless range.is_a?(Hash)
      add_error("report_metadata.report_date_range", "This field is required and must be an object.")
    else
      validate_required_date(range, "start_date", "report_metadata.report_date_range.start_date")
      validate_required_date(range, "end_date", "report_metadata.report_date_range.end_date")
    end

    validate_required_datetime(meta, "consent_timestamp_utc", "report_metadata.consent_timestamp_utc")
  end

  # --- Client Information ---

  def validate_client_information
    client = @payload["client_information"]
    unless client.is_a?(Hash)
      add_error("client_information", "This field is required and must be an object.")
    end
  end

  # --- Employment Records ---

  def validate_employment_records
    records = @payload["employment_records"]
    unless records.is_a?(Array)
      add_error("employment_records", "This field is required and must be an array.")
      return
    end

    records.each_with_index do |record, i|
      validate_employment_record(record, "employment_records[#{i}]")
    end
  end

  def validate_employment_record(record, prefix)
    unless record.is_a?(Hash)
      add_error(prefix, "Must be an object.")
      return
    end

    emp_type = record["employment_type"]
    validate_required_enum(record, "employment_type", EMPLOYMENT_TYPES, "#{prefix}.employment_type")

    validate_employer_information(record["employer_information"], "#{prefix}.employer_information")

    if record.key?("employment_status") && !record["employment_status"].nil?
      validate_nullable_enum(record, "employment_status", EMPLOYMENT_STATUSES, "#{prefix}.employment_status")
    end

    validate_nullable_date(record, "employment_start_date", "#{prefix}.employment_start_date")
    validate_nullable_date(record, "employment_end_date", "#{prefix}.employment_end_date")

    validate_employee_information(record["employee_information"], "#{prefix}.employee_information")

    validate_required_enum(record, "pay_frequency", PAY_FREQUENCIES, "#{prefix}.pay_frequency")

    if record.key?("base_compensation") && !record["base_compensation"].nil?
      validate_base_compensation(record["base_compensation"], "#{prefix}.base_compensation")
    end

    if emp_type == "W2"
      validate_w2_monthly_summaries(record["w2_monthly_summaries"], "#{prefix}.w2_monthly_summaries")
      validate_w2_payments(record["w2_payments"], "#{prefix}.w2_payments")
    elsif emp_type == "GIG"
      validate_gig_monthly_summaries(record["gig_monthly_summaries"], "#{prefix}.gig_monthly_summaries")
      validate_gig_payments(record["gig_payments"], "#{prefix}.gig_payments")
    end
  end

  def validate_employer_information(info, prefix)
    unless info.is_a?(Hash)
      add_error(prefix, "This field is required and must be an object.")
      return
    end

    validate_required_string(info, "employer_name", "#{prefix}.employer_name")
    validate_nullable_string(info, "employer_phone", "#{prefix}.employer_phone")

    if info.key?("employer_address") && !info["employer_address"].nil?
      validate_address(info["employer_address"], "#{prefix}.employer_address")
    end
  end

  def validate_employee_information(info, prefix)
    unless info.is_a?(Hash)
      add_error(prefix, "This field is required and must be an object.")
      return
    end

    validate_nullable_string(info, "full_name", "#{prefix}.full_name")

    if info.key?("ssn") && !info["ssn"].nil?
      unless info["ssn"].is_a?(String) && info["ssn"].match?(SSN_REGEX)
        add_error("#{prefix}.ssn", "Must match format XXX-XX-1234.")
      end
    end
  end

  def validate_base_compensation(comp, prefix)
    unless comp.is_a?(Hash)
      add_error(prefix, "Must be an object when present.")
      return
    end

    validate_nullable_decimal(comp, "rate", "#{prefix}.rate")

    if comp.key?("interval") && !comp["interval"].nil?
      validate_nullable_enum(comp, "interval", BASE_COMPENSATION_INTERVALS, "#{prefix}.interval")
    end
  end

  # --- Address ---

  def validate_address(addr, prefix)
    unless addr.is_a?(Hash)
      add_error(prefix, "Must be an object.")
      return
    end

    %w[line1 line2 city state postal_code country].each do |field|
      validate_nullable_string(addr, field, "#{prefix}.#{field}")
    end
  end

  # --- W2 Monthly Summaries ---

  def validate_w2_monthly_summaries(summaries, prefix)
    return if summaries.nil?
    unless summaries.is_a?(Array)
      add_error(prefix, "Must be an array or null.")
      return
    end

    summaries.each_with_index do |s, i|
      p = "#{prefix}[#{i}]"
      unless s.is_a?(Hash)
        add_error(p, "Must be an object.")
        next
      end

      if !s.key?("month") || s["month"].nil?
        add_error("#{p}.month", "This field is required.")
      elsif !s["month"].is_a?(Integer) || s["month"] < 1 || s["month"] > 12
        add_error("#{p}.month", "Must be an integer between 1 and 12.")
      end

      validate_required_year(s, "year", "#{p}.year")
      validate_nullable_decimal(s, "total_hours", "#{p}.total_hours")

      if !s.key?("number_of_paychecks") || s["number_of_paychecks"].nil?
        add_error("#{p}.number_of_paychecks", "This field is required.")
      elsif !s["number_of_paychecks"].is_a?(Integer)
        add_error("#{p}.number_of_paychecks", "Must be an integer.")
      end

      validate_required_decimal(s, "gross_income", "#{p}.gross_income")

      if !s.key?("partial_month")
        add_error("#{p}.partial_month", "This field is required.")
      elsif ![true, false].include?(s["partial_month"])
        add_error("#{p}.partial_month", "Must be a boolean.")
      end

      validate_nullable_date(s, "partial_month_start", "#{p}.partial_month_start")
      validate_nullable_date(s, "partial_month_end", "#{p}.partial_month_end")
    end
  end

  # --- Gig Monthly Summaries ---

  def validate_gig_monthly_summaries(summaries, prefix)
    return if summaries.nil?
    unless summaries.is_a?(Array)
      add_error(prefix, "Must be an array or null.")
      return
    end

    summaries.each_with_index do |s, i|
      p = "#{prefix}[#{i}]"
      unless s.is_a?(Hash)
        add_error(p, "Must be an object.")
        next
      end

      if !s.key?("month") || s["month"].nil?
        add_error("#{p}.month", "This field is required.")
      elsif !s["month"].is_a?(Integer) || s["month"] < 1 || s["month"] > 12
        add_error("#{p}.month", "Must be an integer between 1 and 12.")
      end
      validate_required_year(s, "year", "#{p}.year")
      validate_nullable_decimal(s, "total_hours", "#{p}.total_hours")
      validate_nullable_decimal(s, "gross_earnings", "#{p}.gross_earnings")

      if s.key?("mileage_expenses") && !s["mileage_expenses"].nil?
        unless s["mileage_expenses"].is_a?(Array)
          add_error("#{p}.mileage_expenses", "Must be an array or null.")
        else
          s["mileage_expenses"].each_with_index do |exp, j|
            ep = "#{p}.mileage_expenses[#{j}]"
            unless exp.is_a?(Hash)
              add_error(ep, "Must be an object.")
              next
            end
            validate_nullable_decimal(exp, "rate", "#{ep}.rate")
            validate_nullable_decimal(exp, "miles", "#{ep}.miles")
          end
        end
      end
    end
  end

  # --- W2 Payments ---

  def validate_w2_payments(payments, prefix)
    return if payments.nil?
    unless payments.is_a?(Array)
      add_error(prefix, "Must be an array or null.")
      return
    end

    payments.each_with_index do |pay, i|
      p = "#{prefix}[#{i}]"
      unless pay.is_a?(Hash)
        add_error(p, "Must be an object.")
        next
      end

      validate_nullable_date(pay, "pay_date", "#{p}.pay_date")

      if pay.key?("pay_period") && !pay["pay_period"].nil?
        pp_obj = pay["pay_period"]
        unless pp_obj.is_a?(Hash)
          add_error("#{p}.pay_period", "Must be an object or null.")
        else
          # Accept both start/end (spec) and start_date/end_date (sample)
          validate_nullable_date(pp_obj, "start", "#{p}.pay_period.start") if pp_obj.key?("start")
          validate_nullable_date(pp_obj, "start_date", "#{p}.pay_period.start_date") if pp_obj.key?("start_date")
          validate_nullable_date(pp_obj, "end", "#{p}.pay_period.end") if pp_obj.key?("end")
          validate_nullable_date(pp_obj, "end_date", "#{p}.pay_period.end_date") if pp_obj.key?("end_date")
        end
      end

      validate_required_decimal(pay, "gross_pay", "#{p}.gross_pay")
      validate_required_decimal(pay, "net_pay", "#{p}.net_pay")
      validate_nullable_decimal(pay, "hours_worked", "#{p}.hours_worked")
      validate_nullable_decimal(pay, "base_hours_paid", "#{p}.base_hours_paid")
      validate_required_decimal(pay, "gross_pay_ytd", "#{p}.gross_pay_ytd")

      validate_gross_pay_line_items(pay["gross_pay_line_items"], "#{p}.gross_pay_line_items")
      validate_deductions(pay["deductions"], "#{p}.deductions")
    end
  end

  def validate_gross_pay_line_items(items, prefix)
    if items.nil?
      add_error(prefix, "This field is required.")
      return
    end
    unless items.is_a?(Array)
      add_error(prefix, "Must be an array.")
      return
    end

    items.each_with_index do |item, j|
      ip = "#{prefix}[#{j}]"
      unless item.is_a?(Hash)
        add_error(ip, "Must be an object.")
        next
      end
      validate_nullable_string(item, "name", "#{ip}.name")
      validate_required_decimal(item, "amount", "#{ip}.amount")
    end
  end

  def validate_deductions(deductions, prefix)
    if deductions.nil?
      add_error(prefix, "This field is required.")
      return
    end
    unless deductions.is_a?(Array)
      add_error(prefix, "Must be an array.")
      return
    end

    deductions.each_with_index do |d, j|
      dp = "#{prefix}[#{j}]"
      unless d.is_a?(Hash)
        add_error(dp, "Must be an object.")
        next
      end
      validate_nullable_string(d, "name", "#{dp}.name")
      validate_required_enum(d, "type", DEDUCTION_TYPES, "#{dp}.type")
      validate_required_decimal(d, "amount", "#{dp}.amount")
    end
  end

  # --- Gig Payments ---

  def validate_gig_payments(payments, prefix)
    return if payments.nil?
    unless payments.is_a?(Array)
      add_error(prefix, "Must be an array or null.")
      return
    end

    payments.each_with_index do |pay, i|
      p = "#{prefix}[#{i}]"
      unless pay.is_a?(Hash)
        add_error(p, "Must be an object.")
        next
      end
      validate_required_date(pay, "pay_date", "#{p}.pay_date")
      validate_required_decimal(pay, "amount", "#{p}.amount")
    end
  end

  # --- Primitive validators ---

  def validate_required_string(hash, key, field_path)
    if !hash.key?(key) || hash[key].nil?
      add_error(field_path, "This field is required.")
    elsif !hash[key].is_a?(String) || hash[key].strip.empty?
      add_error(field_path, "Must be a non-empty string.")
    end
  end

  def validate_nullable_string(hash, key, field_path)
    return unless hash.key?(key) && !hash[key].nil?
    unless hash[key].is_a?(String)
      add_error(field_path, "Must be a string or null.")
    end
  end

  def validate_required_date(hash, key, field_path)
    if !hash.key?(key) || hash[key].nil?
      add_error(field_path, "This field is required.")
    elsif !hash[key].is_a?(String) || !hash[key].match?(DATE_REGEX)
      add_error(field_path, "Must be a date in YYYY-MM-DD format.")
    end
  end

  def validate_nullable_date(hash, key, field_path)
    return unless hash.key?(key) && !hash[key].nil?
    unless hash[key].is_a?(String) && hash[key].match?(DATE_REGEX)
      add_error(field_path, "Must be a date in YYYY-MM-DD format or null.")
    end
  end

  def validate_required_datetime(hash, key, field_path)
    if !hash.key?(key) || hash[key].nil?
      add_error(field_path, "This field is required.")
    elsif !hash[key].is_a?(String) || !hash[key].match?(DATETIME_REGEX)
      add_error(field_path, "Must be a datetime in YYYY-MM-DDTHH:MM:SSZ format.")
    end
  end

  def validate_required_enum(hash, key, allowed, field_path)
    if !hash.key?(key) || hash[key].nil?
      add_error(field_path, "This field is required.")
    elsif !allowed.include?(hash[key])
      add_error(field_path, "Must be one of: #{allowed.join(', ')}.")
    end
  end

  def validate_nullable_enum(hash, key, allowed, field_path)
    return unless hash.key?(key) && !hash[key].nil?
    unless allowed.include?(hash[key])
      add_error(field_path, "Must be one of: #{allowed.join(', ')}.")
    end
  end

  def validate_required_decimal(hash, key, field_path)
    if !hash.key?(key) || hash[key].nil?
      add_error(field_path, "This field is required.")
    elsif !hash[key].is_a?(Numeric)
      add_error(field_path, "Must be a number.")
    end
  end

  def validate_nullable_decimal(hash, key, field_path)
    return unless hash.key?(key) && !hash[key].nil?
    unless hash[key].is_a?(Numeric)
      add_error(field_path, "Must be a number or null.")
    end
  end

  def validate_required_year(hash, key, field_path)
    if !hash.key?(key) || hash[key].nil?
      add_error(field_path, "This field is required.")
    elsif !hash[key].is_a?(String) || !hash[key].match?(YEAR_REGEX)
      add_error(field_path, "Must be a 4-digit year string in YYYY format.")
    end
  end
end
