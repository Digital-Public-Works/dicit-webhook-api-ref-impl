require_relative "test_helper"
require "yaml"

# The report shapes VMI's CbvFlowToJson actually produces (including the edge
# cases its payroll data can cause), checked against IncomeReportValidator.
class VmiPayloadTest < Minitest::Test
  include WebhookTestHelpers

  def w2_record
    {
      "employment_type" => "W2",
      "employer_information" => { "employer_name" => "General Hospital Systems", "employer_phone" => "312-555-0456", "employer_address" => nil },
      "employment_status" => "EMPLOYED",
      "employment_start_date" => "2025-12-29",
      "employment_end_date" => nil,
      "employee_information" => { "first_name" => "Elena", "last_name" => "Thompson", "full_name" => "Elena Thompson", "ssn" => "XXX-XX-4455" },
      "pay_frequency" => "BIWEEKLY",
      "base_compensation" => { "rate" => 32.5, "interval" => "HOURLY" },
      "w2_monthly_summaries" => [
        { "month" => 1, "year" => "2026", "total_hours" => 80.0, "number_of_paychecks" => 1, "gross_income" => 2600.0,
          "partial_month" => false, "partial_month_start" => nil, "partial_month_end" => nil }
      ],
      "w2_payments" => [
        { "pay_date" => "2026-01-09", "pay_period" => { "start" => "2025-12-29", "end" => "2026-01-04" },
          "gross_pay" => 2600.0, "net_pay" => 1950.4, "hours_worked" => 80.0, "base_hours_paid" => 80.0, "gross_pay_ytd" => 2600.0,
          "gross_pay_line_items" => [ { "name" => "Regular", "amount" => 2600.0 } ],
          "deductions" => [ { "name" => "401k", "amount" => 260.0, "type" => "PRETAX" } ],
          "direct_deposit_accounts" => [], "payout_card_accounts" => [] }
      ],
      "gig_monthly_summaries" => nil,
      "gig_payments" => nil
    }
  end

  def gig_record
    {
      "employment_type" => "GIG",
      "employer_information" => { "employer_name" => "DoorDash", "employer_phone" => nil, "employer_address" => nil },
      "employment_status" => "EMPLOYED",
      "employment_start_date" => "2025-05-20",
      "employment_end_date" => nil,
      "employee_information" => { "first_name" => "Elena", "last_name" => "Thompson", "full_name" => "Elena Thompson", "ssn" => "XXX-XX-4455" },
      "pay_frequency" => "VARIABLE",
      "base_compensation" => { "rate" => nil, "interval" => nil },
      "gig_monthly_summaries" => [
        { "month" => 12, "year" => "2025", "total_hours" => 128.5, "gross_earnings" => 1336.45,
          "mileage_expenses" => [ { "miles" => 585.33054, "rate" => 0.7 } ] }
      ],
      "gig_payments" => [ { "pay_date" => "2026-01-26", "amount" => 340.25 } ],
      "w2_monthly_summaries" => nil,
      "w2_payments" => nil
    }
  end

  def vmi_report(records = [ w2_record, gig_record ])
    report_submission(event_type: "ReportSubmission").tap do |payload|
      payload["report_metadata"]["filenames"] = {}
      payload["client_information"]["additional_jobs_to_report"] = nil
      payload["employment_records"] = records
      payload["paystub_images_included"] = false
      payload["attachments"] = {
        "report_filename" => "VMI_00012345_20260513_ConfCONF0001.pdf",
        "paystubs_filename" => "VMI_00012345_20260513_ConfCONF0001_paystubs.pdf"
      }
    end
  end

  def errors_for(payload)
    IncomeReportValidator.new(payload).validate.map { |e| e[:field] }
  end

  def test_a_typical_vmi_report_is_valid
    assert_empty errors_for(vmi_report)
  end

  def test_a_vmi_report_is_accepted_by_the_endpoint
    post_event(vmi_report)
    assert_equal 200, last_response.status, last_response.body
  end

  # --- values VMI can send ---

  def test_a_deduction_amount_may_be_null
    record = w2_record
    record["w2_payments"][0]["deductions"][0]["amount"] = nil
    assert_empty errors_for(vmi_report([ record ]))
  end

  def test_gig_payment_date_and_amount_may_be_null
    record = gig_record
    record["gig_payments"] = [ { "pay_date" => nil, "amount" => nil } ]
    assert_empty errors_for(vmi_report([ record ]))
  end

  def test_employment_status_is_passed_through_from_the_payroll_provider
    record = w2_record
    record["employment_status"] = "FURLOUGHED"
    assert_empty errors_for(vmi_report([ record ]))
  end

  # an account with no employment details: no employer, no identity, and no
  # w2_*/gig_* fields at all
  def test_a_record_without_employment_details
    record = {
      "employment_type" => "",
      "employer_information" => { "employer_name" => nil, "employer_phone" => nil, "employer_address" => nil },
      "employment_status" => nil,
      "employment_start_date" => nil,
      "employment_end_date" => nil,
      "employee_information" => { "first_name" => nil, "last_name" => nil, "full_name" => nil, "ssn" => nil },
      "pay_frequency" => nil,
      "base_compensation" => { "rate" => nil, "interval" => nil }
    }
    assert_empty errors_for(vmi_report([ record ]))
  end

  def test_a_full_ssn_is_whatever_the_provider_returned
    [ "123-45-6789", "9999" ].each do |ssn|
      record = w2_record
      record["employee_information"]["ssn"] = ssn
      assert_empty errors_for(vmi_report([ record ])), ssn
    end
  end

  def test_account_numbers_may_be_shorter_than_four_digits
    record = w2_record
    record["w2_payments"][0]["direct_deposit_accounts"] = [ "1234", "56" ]
    record["w2_payments"][0]["payout_card_accounts"] = [ "7" ]
    assert_empty errors_for(vmi_report([ record ]))
  end

  def test_mileage_miles_may_be_null
    record = gig_record
    record["gig_monthly_summaries"][0]["mileage_expenses"] = [ { "miles" => nil, "rate" => 0.725 } ]
    assert_empty errors_for(vmi_report([ record ]))
  end

  # a month with no gig activity has no rate
  def test_mileage_rate_may_be_null
    record = gig_record
    record["gig_monthly_summaries"][0]["mileage_expenses"] = [ { "miles" => 0.0, "rate" => nil } ]
    assert_empty errors_for(vmi_report([ record ]))
  end

  def test_mileage_rate_must_be_a_number
    record = gig_record
    record["gig_monthly_summaries"][0]["mileage_expenses"][0]["rate"] = "0.725"
    assert_equal [ "employment_records[0].gig_monthly_summaries[0].mileage_expenses[0].rate" ], errors_for(vmi_report([ record ]))
  end

  def test_attachments_are_absent_when_pay_stub_images_are_off
    payload = vmi_report
    payload.delete("attachments")
    assert_empty errors_for(payload)
  end

  # --- values VMI never sends ---

  def test_base_compensation_must_be_an_object
    record = w2_record
    record["base_compensation"] = nil
    assert_equal [ "employment_records[0].base_compensation" ], errors_for(vmi_report([ record ]))
  end

  def test_base_compensation_interval_must_be_one_vmi_sends
    record = w2_record
    record["base_compensation"]["interval"] = "DAILY"
    assert_equal [ "employment_records[0].base_compensation.interval" ], errors_for(vmi_report([ record ]))
  end

  def test_employment_type_must_be_w2_gig_or_empty
    record = w2_record
    record["employment_type"] = "CONTRACTOR"
    assert_equal [ "employment_records[0].employment_type" ], errors_for(vmi_report([ record ]))
  end

  def test_account_numbers_are_at_most_four_digits
    record = w2_record
    record["w2_payments"][0]["direct_deposit_accounts"] = [ "12345" ]
    assert_equal [ "employment_records[0].w2_payments[0].direct_deposit_accounts[0]" ], errors_for(vmi_report([ record ]))
  end

  def test_attachments_need_both_filenames
    payload = vmi_report
    payload["attachments"].delete("paystubs_filename")
    assert_equal [ "attachments.paystubs_filename" ], errors_for(payload)

    payload["attachments"] = "file.pdf"
    assert_equal [ "attachments" ], errors_for(payload)
  end

  # --- the documentation's samples are valid ---

  ROOT = File.expand_path("..", __dir__)

  def test_the_openapi_examples_are_valid
    spec = YAML.load_file(File.join(ROOT, "public/openapi.yaml"))
    examples = spec.dig("paths", "/api/v1/income-report", "post", "requestBody", "content", "application/json", "examples")
    assert_empty IncomeReportValidator.new(examples.dig("reportSubmission", "value")).validate
    assert_empty TransmissionCompleteValidator.new(examples.dig("transmissionComplete", "value")).validate
  end

  def test_the_spec_sample_payload_is_valid
    spec = File.read(File.join(ROOT, "Webhooks Data Transmission Spec v1.md"))
    sample = spec[/### Sample Payload.*?\n\n(\{.*?\n\})\n```/m, 1]
    refute_nil sample, "couldn't find the sample payload in the spec"
    assert_empty IncomeReportValidator.new(JSON.parse(sample)).validate
  end
end
