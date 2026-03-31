# VMI Webhook API Reference Implementation

A Ruby reference implementation of the **Verify My Income (VMI) Webhooks Data Transmission Spec v1**. This server acts as a partner-side receiver: it accepts incoming income report webhooks from the VMI platform, validates headers, verifies HMAC signatures, validates the JSON payload against the spec, and returns appropriate HTTP status codes.

There is no data store — the server validates and responds only.

## Prerequisites

- Ruby 3.4+
- Bundler

## Setup

```bash
bundle install
```

## Running the Server

```bash
bundle exec rackup -p 9292 -o 0.0.0.0
```

The server starts on port 9292 by default. Open http://localhost:9292 for the Swagger UI.

### Running with Docker

```bash
docker build -t vmi-webhook-api .
docker run --rm -p 9292:9292 vmi-webhook-api
```

To pass configuration:

```bash
docker run --rm -p 9292:9292 \
  -e VMI_API_KEY=my-secure-guid \
  -e VERIFY_SIGNATURE=true \
  vmi-webhook-api
```

## Available Endpoints

| Path | Method | Description |
|------|--------|-------------|
| `/` | GET | Redirects to Swagger UI |
| `/swagger.html` | GET | Interactive API documentation (Swagger UI) |
| `/openapi.yaml` | GET | OpenAPI 3.0 spec file |
| `/api/v1/income-report` | POST | Receive and validate an income report |

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `VMI_API_KEY` | `abc123_example_key` | The API key to validate against the `X-VMI-API-Key` header |
| `VERIFY_SIGNATURE` | `false` | Set to `true` to enable HMAC signature verification |

> **Note:** Signature verification is disabled by default because this is a reference
> implementation intended for development and testing. In a production deployment,
> the implementing partner should enable signature verification (`VERIFY_SIGNATURE=true`)
> to ensure that incoming requests are authentically signed by the VMI platform.

Example with signature verification enabled:

```bash
VMI_API_KEY=my-secure-guid VERIFY_SIGNATURE=true bundle exec rackup -p 9292
```

## Authentication

Every request to `/api/v1/income-report` must include these headers:

| Header | Description |
|--------|-------------|
| `X-VMI-API-Key` | Must match the configured `VMI_API_KEY` |
| `X-VMI-Timestamp` | Unix epoch seconds (numeric string) |
| `X-VMI-Signature` | HMAC-SHA512 hex digest of `"<timestamp>:<body>"` keyed with the API key |
| `X-VMI-Confirmation-Code` | Unique confirmation code for the record |
| `Content-Type` | Must be `application/json` |

### Signature Algorithm

The signature is computed as:

```
HMAC-SHA512(key: api_key, message: "<timestamp>:<request_body>")
```

This matches the signing logic in the VMI platform (`JsonApiSignature`).

## Validation

The server validates the full payload structure per the spec:

- **Report Metadata** — `confirmation_code`, `report_date_range` (start/end dates), `consent_timestamp_utc`
- **Client Information** — must be an object (fields vary by partner)
- **Employment Records** — array of W2 or GIG records, each validated for:
  - `employment_type` enum (`W2`, `GIG`)
  - `employment_status` enum (`EMPLOYED`, `ACTIVE`, `INACTIVE`, `TERMINATED`)
  - `employer_information` with required `employer_name` and optional `employer_address` (`line1`, `line2`, `city`, `state`, `postal_code`, `country`)
  - `employee_information` with optional SSN format validation (`XXX-XX-1234`)
  - `employment_start_date` and `employment_end_date` (nullable date fields)
  - `pay_frequency` enum (`ANNUALLY`, `BIWEEKLY`, `DAILY`, `HOURLY`, `MONTHLY`, `QUARTERLY`, `SEMIMONTHLY`, `WEEKLY`)
  - `base_compensation` (nullable) — `rate` + `interval` enum (`HOURLY`, `DAILY`, `WEEKLY`, `BIWEEKLY`, `SEMIMONTHLY`, `MONTHLY`, `ANNUAL`, `SALARY`)
  - **W2** (nullable): `w2_monthly_summaries` (month 1-12, year, `number_of_paychecks`, `gross_income`, partial month fields), `w2_payments` (gross/net pay, YTD, line items, deductions with `PRETAX`/`POSTTAX`/`UNKNOWN` type)
  - **GIG** (nullable): `gig_monthly_summaries` (month 1-12, year, hours, `gross_earnings`, mileage expenses), `gig_payments` (pay date + amount)

Date fields must be `YYYY-MM-DD`, datetimes must be `YYYY-MM-DDTHH:MM:SSZ`.

## Response Codes

| Code | Meaning |
|------|---------|
| 200 | Payload accepted and valid |
| 400 | JSON parse error (`PARSE_ERROR`) or validation failure (`VALIDATION_ERROR`) — returns field-level error details |
| 401 | Missing headers, bad API key, or signature verification failure |
| 404 | Unknown endpoint |
| 405 | Method not allowed (only POST is accepted for the income report endpoint) |

Error responses follow the spec format:

```json
{
  "error_code": "VALIDATION_ERROR",
  "message": "The request was well-formed but contains errors.",
  "errors": [
    { "field": "employment_records[0].pay_frequency", "reason": "Must be one of: ANNUALLY, BIWEEKLY, ..." },
    { "field": "report_metadata.consent_timestamp_utc", "reason": "This field is required." }
  ]
}
```

## Testing with curl

Generate a signed request:

```bash
API_KEY="abc123_example_key"
TIMESTAMP=$(date +%s)
BODY='{"report_metadata":{"confirmation_code":"TEST001","report_date_range":{"start_date":"2025-11-01","end_date":"2026-02-01"},"consent_timestamp_utc":"2026-02-01T10:30:00Z"},"client_information":{"case_number":"CASE-123"},"employment_records":[{"employment_type":"W2","employer_information":{"employer_name":"Acme Corp","employer_phone":null,"employer_address":null},"employee_information":{"full_name":"John Doe","ssn":"XXX-XX-1234"},"pay_frequency":"BIWEEKLY","base_compensation":{"rate":25.00,"interval":"HOURLY"},"w2_monthly_summaries":[{"month":1,"year":"2026","total_hours":160.0,"number_of_paychecks":2,"gross_income":4000.00,"partial_month":false,"partial_month_start":null,"partial_month_end":null}],"w2_payments":[{"pay_date":"2026-01-15","pay_period":{"start":"2026-01-01","end":"2026-01-14"},"gross_pay":2000.00,"net_pay":1500.00,"hours_worked":80.0,"base_hours_paid":80.0,"gross_pay_ytd":2000.00,"gross_pay_line_items":[{"name":"Regular","amount":2000.00}],"deductions":[{"name":"Federal Tax","type":"PRETAX","amount":300.00}]}],"gig_monthly_summaries":null,"gig_payments":null}]}'

SIGNATURE=$(echo -n "${TIMESTAMP}:${BODY}" | openssl dgst -sha512 -hmac "${API_KEY}" | sed 's/.*= //')

curl -X POST http://localhost:9292/api/v1/income-report \
  -H "Content-Type: application/json" \
  -H "X-VMI-Timestamp: ${TIMESTAMP}" \
  -H "X-VMI-Signature: ${SIGNATURE}" \
  -H "X-VMI-Confirmation-Code: TEST001" \
  -H "X-VMI-API-Key: ${API_KEY}" \
  -d "${BODY}"
```

Since signature verification is off by default, you can also test without computing a signature — just pass any non-empty value for `X-VMI-Signature`.

## Integration Tests

The VMI Rails application (`dicit`) includes integration tests that send real HTTP requests to this reference server. These tests exercise the full webhook delivery pipeline — signing, header construction, payload serialization, and response handling — against a running instance of this server with signature verification enabled.

To run the integration tests:

1. Start this reference server with signature verification enabled:

```bash
cd /path/to/dicit-webhook-api-ref-impl
VMI_API_KEY=my-secure-guid VERIFY_SIGNATURE=true bundle exec rackup -p 9292
```

2. In a separate terminal, run the integration spec from the Rails app:

```bash
cd /path/to/dicit/app
INTEGRATION_RUN_TESTS=1 bundle exec rspec spec/services/transmitters/webhook_transmitter_integration_spec.rb
```

> **Note:** The integration tests are gated behind the `INTEGRATION_RUN_TESTS` environment variable so they don't run during normal CI — they require this server to be running locally.

## Project Structure

```
├── .dockerignore                    # Files excluded from Docker build
├── .ruby-version                    # Ruby version (3.4.5)
├── Dockerfile                       # Container image definition
├── Gemfile                          # Dependencies (sinatra, puma, rackup)
├── Gemfile.lock                     # Locked dependency versions
├── config.ru                        # Rack entry point
├── app.rb                           # Sinatra application (routes, header validation)
├── lib/
│   ├── income_report_validator.rb   # Full payload validation per spec
│   └── signature_verifier.rb        # HMAC-SHA512 signature generation/verification
├── public/
│   ├── openapi.yaml                 # OpenAPI 3.0 specification
│   └── swagger.html                 # Swagger UI (loads from CDN)
└── Webhooks Data Transmission Spec V1.pdf  # Source spec document
```

## Spec Reference

See `Webhooks Data Transmission Spec V1.pdf` in this directory for the full API specification.
