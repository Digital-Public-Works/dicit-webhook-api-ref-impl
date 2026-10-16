# VMI Webhook API Reference Implementation

A Ruby reference implementation of the **Verify My Income (VMI) Webhooks Data Transmission Spec v1**. This server acts as a partner-side receiver: it accepts incoming webhook events from the VMI platform (`ReportSubmission` and `TransmissionComplete`), validates headers, verifies HMAC signatures, validates the JSON payload against the spec, and returns appropriate HTTP status codes.

It accepts both webhook contract versions (see [Webhook Events and Contract Versions](#webhook-events-and-contract-versions)), so it also shows how a partner can move from contract 1 to contract 2 without a coordinated cutover.

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
  vmi-webhook-api
```

To dump received payloads to a local directory for inspection:

```bash
mkdir -p ./tmp/payloads
docker run --rm -p 9292:9292 \
  -e VMI_API_KEY=my-secure-guid \
  -e PAYLOAD_DIR=/data/payloads \
  -v "$(pwd)/tmp/payloads:/data/payloads" \
  vmi-webhook-api
```

## Available Endpoints

| Path | Method | Description |
|------|--------|-------------|
| `/` | GET | Redirects to Swagger UI |
| `/swagger.html` | GET | Interactive API documentation (Swagger UI) |
| `/openapi.yaml` | GET | OpenAPI 3.0 spec file |
| `/api/v1/income-report` | POST | Receive and validate webhook events (`ReportSubmission`, `TransmissionComplete`) |

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `VMI_API_KEY` | `abc123_example_key` | The shared secret used to verify `X-VMI-Signature` |
| `PAYLOAD_DIR` | *(unset)* | When set, accepted payloads are saved as JSON files to this directory (e.g. `/data/payloads`). A ReportSubmission is saved as `{timestamp}_{confirmation_code}.json`; a TransmissionComplete as `{timestamp}_{confirmation_code}_TransmissionComplete_{transmission_method}.json`. |

Signature verification is always on: it is the only authentication. (Earlier versions always compared the `X-VMI-API-Key` header and verified signatures only when `VERIFY_SIGNATURE=true`. Both behaviors are gone, and `VERIFY_SIGNATURE` is no longer read.)

## Webhook Events and Contract Versions

VMI configures each partner's webhook with a contract version. This server accepts both on the same endpoint:

| | Contract 1 (legacy) | Contract 2 |
|---|---|---|
| `event_type` in the body | Absent; every request is a ReportSubmission | `ReportSubmission` or `TransmissionComplete` |
| `X-VMI-API-Key` header | Sent by VMI; ignored here | Not sent |
| `TransmissionComplete` events | Not sent | One per completed non-webhook transmission method |

Requests are routed on `event_type`:

- absent or `ReportSubmission` → validated as an income report;
- `TransmissionComplete` → validated as a transmission-complete event;
- any other string → accepted with `200` and `"status": "ignored"`, so new VMI event types don't cause failed deliveries.

A `TransmissionComplete` tells the partner that a file VMI delivered by another method (SFTP or S3) has arrived:

```json
{
  "event_type": "TransmissionComplete",
  "confirmation_code": "TEST001",
  "transmission_method": "sftp",
  "uri": "inbox/VMI_00012345_20260513_ConfTEST001.pdf",
  "completed_at": "2026-05-13T18:04:11Z"
}
```

`uri` is the same value as `report_metadata.filenames[transmission_method]` in the ReportSubmission, or `null` for methods that don't produce a file. Events can arrive in any order and more than once; see the spec for details.

## Authentication

Every request to `/api/v1/income-report` must include these headers:

| Header | Description |
|--------|-------------|
| `X-VMI-Timestamp` | Unix epoch seconds (numeric string) |
| `X-VMI-Signature` | HMAC-SHA512 hex digest of `"<timestamp>:<body>"` keyed with the API key |
| `X-VMI-Confirmation-Code` | Unique confirmation code for the record |
| `Content-Type` | Must be `application/json` |

`X-VMI-API-Key` is not required. VMI sends it only under contract 1, and this server ignores it: authentication is by signature alone.

### Signature Algorithm

The signature is computed as:

```
HMAC-SHA512(key: api_key, message: "<timestamp>:<request_body>")
```

This matches the signing logic in the VMI platform (`JsonApiSignature`).

## Validation

A `TransmissionComplete` must have a non-empty `confirmation_code` and `transmission_method` (any string; known values are `sftp`, `encrypted_s3`, `unencrypted_s3`, `shared_email`, `json`), a `uri` key holding a string or `null`, and a `completed_at` datetime.

For a ReportSubmission, the server validates the full payload structure per the spec:

- **Report Metadata** — `confirmation_code`, `report_date_range` (start/end dates), `consent_timestamp_utc`, optional `filenames` map of transmission method (`sftp`, `encrypted_s3`, `unencrypted_s3`) → companion filename
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
- **Paystub Images Included** — top-level `paystub_images_included` boolean indicating whether a companion pay stub images file has been delivered with at least one actual pay stub image; `false` when the partner does not have pay stub images enabled.

Date fields must be `YYYY-MM-DD`, datetimes must be `YYYY-MM-DDTHH:MM:SSZ`.

## Response Codes

| Code | Meaning |
|------|---------|
| 200 | Event accepted and valid (`"status": "success"`), or an unrecognized `event_type` was ignored (`"status": "ignored"`) |
| 400 | JSON parse error (`PARSE_ERROR`) or validation failure (`VALIDATION_ERROR`) — returns field-level error details |
| 401 | Missing headers or signature verification failure |
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

Generate a signed request. This body has no `event_type`, i.e. a contract 1 ReportSubmission; add `"event_type":"ReportSubmission",` at the start of the object for contract 2.

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
  -d "${BODY}"
```

A TransmissionComplete event, signed the same way:

```bash
API_KEY="abc123_example_key"
TIMESTAMP=$(date +%s)
BODY='{"event_type":"TransmissionComplete","confirmation_code":"TEST001","transmission_method":"sftp","uri":"inbox/VMI_00012345_20260513_ConfTEST001.pdf","completed_at":"2026-05-13T18:04:11Z"}'

SIGNATURE=$(echo -n "${TIMESTAMP}:${BODY}" | openssl dgst -sha512 -hmac "${API_KEY}" | sed 's/.*= //')

curl -X POST http://localhost:9292/api/v1/income-report \
  -H "Content-Type: application/json" \
  -H "X-VMI-Timestamp: ${TIMESTAMP}" \
  -H "X-VMI-Signature: ${SIGNATURE}" \
  -H "X-VMI-Confirmation-Code: TEST001" \
  -d "${BODY}"
```

Signatures are always verified, so every request must be signed as above.

## Integration Tests

The VMI Rails application (`dicit`) includes integration tests that send real HTTP requests to this reference server. These tests exercise the full webhook delivery pipeline — signing, header construction, payload serialization, and response handling — against a running instance of this server.

To run the integration tests:

1. Start this reference server:

```bash
cd /path/to/dicit-webhook-api-ref-impl
VMI_API_KEY=my-secure-guid bundle exec rackup -p 9292
```

2. In a separate terminal, run the integration spec from the Rails app:

```bash
cd /path/to/dicit/app
INTEGRATION_RUN_TESTS=1 bundle exec rspec spec/services/transmitters/webhook_transmitter_integration_spec.rb
```

> **Note:** When running `rspec` directly, the integration tests are gated behind the `INTEGRATION_RUN_TESTS` environment variable because they need this server running. VMI's `rspec-integration` CI job builds this repository's `main` branch and runs them on every VMI pull request, so changes merged here are exercised by VMI's CI.

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
│   ├── income_report_validator.rb   # ReportSubmission payload validation per spec
│   ├── transmission_complete_validator.rb  # TransmissionComplete event validation
│   └── signature_verifier.rb        # HMAC-SHA512 signature generation/verification
├── public/
│   ├── openapi.yaml                 # OpenAPI 3.0 specification
│   └── swagger.html                 # Swagger UI (loads from CDN)
└── Webhooks Data Transmission Spec v1.md   # Source spec document
```

## Spec Reference

See `Webhooks Data Transmission Spec v1.md` in this directory for the full API specification.
