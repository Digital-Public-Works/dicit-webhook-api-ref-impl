require_relative "test_helper"

class IncomeReportValidatorTest < Minitest::Test
  include WebhookTestHelpers

  def errors_for(payload)
    IncomeReportValidator.new(payload).validate.map { |e| e[:field] }
  end

  def with_additional_jobs(value)
    report_submission.tap { |payload| payload["client_information"]["additional_jobs_to_report"] = value }
  end

  def test_additional_jobs_to_report_may_be_true_or_false
    assert_empty errors_for(with_additional_jobs(true))
    assert_empty errors_for(with_additional_jobs(false))
  end

  # partners that skip the other-jobs question send null
  def test_additional_jobs_to_report_may_be_null
    assert_empty errors_for(with_additional_jobs(nil))
  end

  def test_additional_jobs_to_report_may_be_absent
    assert_empty errors_for(report_submission)
  end

  def test_additional_jobs_to_report_must_be_a_boolean
    assert_equal ["client_information.additional_jobs_to_report"], errors_for(with_additional_jobs("yes"))
  end

  def test_other_client_information_fields_are_not_checked
    payload = report_submission
    payload["client_information"]["anything"] = { "nested" => [1, nil] }
    assert_empty errors_for(payload)
  end
end
