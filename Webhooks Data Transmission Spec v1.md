# Webhooks Data Transmission Spec v1

| **Date** | **Revision Note** |
| --- | --- |
| 2/9/2026 | Initial document created |
| 3/10/2026 | Update partial_month documentation and add partial_month_start and partial_month_end |
| 3/12/2026 | Update month to be integer instead of 3 letter code |
| 3/27/2026 | Make pay_frequency nullable, fix sample payload pay_period fields, add deductions nullable, clarify partial_month fields |
| 4/3/2026 | Add first_name and last_name to employee_information |
| 5/15/2026 | Add optional filenames object to report_metadata to identify companion files transmitted via SFTP or S3 |
| 6/10/2026 | Add optional sensitive fields (off by default): direct_deposit_accounts and payout_card_accounts last-4 arrays on W2 payments, and optional full unmasked SSN |
| 6/12/2026 | Add optional top-level paystub_images_included flag indicating whether the companion pay stub images file contains any pay stub images |
| 10/15/2026 | Add webhook contract version 2: top-level `event_type`, new `TransmissionComplete` event, and authentication by `X-VMI-Signature` only (`X-VMI-API-Key` deprecated) |
| 10/21/2026 | Clarify that `filenames` values (and `TransmissionComplete` `uri`) are remote paths and document the `VMI_` prefix; state that `X-VMI-Confirmation-Code` equals the body's confirmation code; explain how contract versions relate to the API version; reject stale timestamps with 401; document `client_information.additional_jobs_to_report` (nullable boolean) and that unfilled `client_information` fields are sent as `null` |
| 10/23/2026 | Align field definitions with what VMI sends: document `attachments`; `employer_address` is currently always `null`; `mileage_expenses[].rate` is the federal mileage rate in dollars per mile; `base_compensation` is always an object; `employment_status` is passed through from the payroll provider; `employment_type` may be empty; `employer_name`, deduction `amount` and gig payment fields may be `null`; full SSN and account numbers are sent only when the payroll provider makes them available; reporting window is 90 or 182 days; error handling table and retry logic describe what VMI does |

# Introduction

This document outlines the API specification implemented by partners to receive structured JSON representations of income verification data from the Verify My Income platform. 

VMI sends two kinds of events to this endpoint:

- **ReportSubmission**: the income report itself.
- **TransmissionComplete**: a notification that a file VMI delivers by another transmission method (for example SFTP or S3) has actually arrived, so the partner can fetch it without polling. Sent under webhook contract version 2 only; see **Webhook Contract Versions**.

The partner must build this API endpoint and ensure that data is ingested into the correct case within the eligibility management system.

# Environments

The partner must provide two distinct endpoints to the VMI team. Each environment will utilize unique API keys.

| **Environment Name** | **VMI Environment** | **Sample Path** |
| --- | --- | --- |
| UAT | Demo | `https://uat.your-agency.gov/api/v1/income-report`  |
| Production | Production | `https://your-agency.gov/api/v1/income-report`  |

# API Specification

## Receive webhook events: POST /api/v1/income-report

- **Method**: `POST`
- **Path**: `/api/v1/income-report`
- **Security:** The endpoint must only accept requests over TLS.
- **Authentication**: The partner supplies a secret API key GUID. VMI signs every request with it (`X-VMI-Signature`), and the partner authenticates each request by verifying that signature. See **Signature Verification**. Under contract version 2 the key itself is never sent.

This API endpoint must be built by the partner and will receive webhook events as structured JSON data. The partner can suggest an alternative path as long as it contains a version number. 

### Versioning Policy

VMI uses semantic versioning in the API path (e.g., /v1/).

Minor Changes: (e.g. adding optional fields) will be done within the current version.

Major Changes: (e.g. removing required fields or changing data types) will result in a new version (e.g., /v2/). 

Partners are expected to build "flexible" parsers that do not fail when encountering new, unrecognized JSON keys.

Webhook contract versions (below) are separate from the API version. A contract version is a per-partner setting that VMI changes only once the partner is ready, so moving to contract 2 is not a breaking change for anyone and both contracts use the `/v1/` endpoint.

### Webhook Contract Versions

VMI configures each partner's webhook with a contract version. Both versions use the same endpoint and the same request signing.

| | **Contract 1 (legacy)** | **Contract 2** |
| --- | --- | --- |
| `event_type` in the body | Not sent. Every request is a ReportSubmission. | Always sent: `ReportSubmission` or `TransmissionComplete`. |
| `X-VMI-API-Key` header | Sent (deprecated). | Not sent. |
| Authentication | Verify `X-VMI-Signature`. | Verify `X-VMI-Signature`. |
| `TransmissionComplete` events | Not sent. | Sent. |

Existing partners are on contract 1 until they move. New integrations should use contract 2. Contract 1 will be retired once every partner has moved.

**Moving to contract 2.** A receiver that handles both contracts can be deployed first, so there is no coordinated cutover:

1. Update the receiver to:
    - authenticate by verifying `X-VMI-Signature` (VMI already sends it under contract 1);
    - not require `X-VMI-API-Key`, and ignore it when present;
    - treat a missing `event_type` as `ReportSubmission`;
    - accept `TransmissionComplete` events;
    - respond 2xx to, and ignore, any `event_type` it doesn't recognize.
2. Tell the VMI team the receiver is ready.
3. VMI switches the partner's webhook to contract 2. This is a configuration change with no downtime. Submissions already in progress at the time of the switch may still arrive in contract 1 format, which the receiver above handles.
4. Confirm that a test submission's `ReportSubmission` (now with `event_type`) and `TransmissionComplete` events arrive, with no `X-VMI-API-Key` header.
5. If anything goes wrong, VMI can switch the partner back to contract 1.

### Request Headers

The following headers are required for every transmission to ensure security and message integrity.

| Header | Description |
| --- | --- |
| `X-VMI-Timestamp` | Seconds since the Unix epoch (used to verify the request signature). |
| `X-VMI-Signature` | Calculated signature based on the request body. |
| `X-VMI-Confirmation-Code` | Unique confirmation code of the submitted record (e.g., "LALDH00100001"). Always equal to the body's confirmation code: `report_metadata.confirmation_code` in a ReportSubmission, `confirmation_code` in a TransmissionComplete. |
| `X-VMI-API-Key` | **Contract 1 only (deprecated).** The partner's API key. Not sent under contract 2. Do not authenticate with it; verify `X-VMI-Signature` instead. |
| `Content-Type` | Must be `application/json`. |
| `Content-Length` | Number of bytes in the body.  |

Additional headers used for authentication may be requested by the partner.

### Signature Verification

`X-VMI-Signature` is the hex-encoded HMAC-SHA512 of `<X-VMI-Timestamp>:<request body>`, keyed with the partner's API key. To authenticate a request:

1. Read the raw request body bytes before parsing the JSON.
2. Compute HMAC-SHA512 (hex) of the `X-VMI-Timestamp` header value, a `:`, and the raw body, using the API key as the secret.
3. Compare the result to `X-VMI-Signature` with a constant-time comparison. If they differ, respond `401`.

Recommended: also reject (with `401`) requests whose `X-VMI-Timestamp` is more than 5 minutes from the receiver's current time, so a captured request can't be replayed later. VMI signs every delivery attempt, including retries, at send time.

### Request Body: ReportSubmission

The request body contains the income data. This payload is formatted as a JSON object to allow for direct field mapping into the eligibility management system.

- **Event Type** (String) — top-level

    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `event_type` | Enum | No (contract 2); absent (contract 1) | Contract 2: `ReportSubmission` for this payload (see **TransmissionComplete Event** for the other value). Absent under contract 1, where every request is a ReportSubmission. Receivers should respond 2xx to, and ignore, values they don't recognize. |

**Data Types**

- **Date:** String in `YYYY-MM-DD` format (ISO-8601).
- **DateTime:** String in `YYYY-MM-DDTHH:MM:SSZ` format (ISO-8601 UTC).
- **Decimal:** Number. Dollar amounts and hours are rounded to two decimal places (the per-mile mileage rate to three); other values (e.g. miles) are not rounded.
- **Enum:** A string that must match a specific set of allowed values.

- **Report Metadata** (object)
    
    
    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `confirmation_code` | String | No | Unique confirmation code of the submitted record. |
    | `report_date_range` | Object | No |  |
    |   ├ `start_date` | Date | No | Earliest date of review period  |
    |   └  `end_date` | Date | No | Last date of review period  |
    | `consent_timestamp_utc` | DateTime | No | Date and time when client provided legal consent for data retrieval. |
    | `filenames` | Object | Yes | Optional map of transmission method to the remote path of the companion file. Always present: lists the files VMI delivers via SFTP or S3 in addition to this webhook, and is an empty object when it delivers none. See **Filenames** below. |

- **Filenames** (object) — optional

    Maps each non-webhook transmission method that the sending agency has configured to the remote path of the companion file delivered on that channel: the SFTP path or S3 object key, i.e. the directory configured for that method (if any), then `/`, then the filename. Receivers can use this to join this webhook payload to the file(s) received on the SFTP / S3 channel(s). The file may not have arrived yet when the ReportSubmission is received; under contract 2, a `TransmissionComplete` event with the same value in `uri` is sent once it has.

    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `sftp` | String | Yes | SFTP path of the PDF, e.g. `inbox/VMI_00012345_20260513_ConfABC123.pdf`. Present only when SFTP transmission is configured. |
    | `encrypted_s3` | String | Yes | S3 object key of the encrypted tarball, e.g. `VMI_00012345_20260513_ConfABC123.tar.gz.gpg`. Present only when encrypted-S3 transmission is configured. |
    | `unencrypted_s3` | String | Yes | S3 object key of the unencrypted tarball, e.g. `VMI_00012345_20260513_ConfABC123.tar.gz`. Present only when unencrypted-S3 transmission is configured. |

    Value format: `[<directory>/]<prefix>_<8-char padded partner_identifier>_<YYYYMMDD in agency tz>_Conf<confirmation_code>.<ext>`. `<prefix>` is `VMI` (`CBVPilot` for some early partners, as in the sample payload). The directory is present only when one is configured for that method. The filename portion is ≤ 100 characters; the directory is not counted. The key `webhook` will never appear (the dict points at companion files, not at this payload itself); methods that produce no file (e.g. `shared_email`, `json`) are also omitted. Partners should treat unknown keys as a no-op (per the flexible-parser guidance above).

- **Client Information** (object) - Varies by partner
    
    This object contains unique identifying information to link the report to the correct record in the partner’s eligibility database. These fields (e.g. `case_number`, `last_name`) will be agreed upon with each partner. 

    Every agreed field is always present. A field the applicant or caseworker didn't fill in (e.g. an optional one) is sent as `null`, not left out, so receivers should accept `null` for any optional field.

    VMI also adds this field for every partner:

    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `additional_jobs_to_report` | Boolean | Yes | The applicant's answer to whether they have other jobs to report that aren't included in this report. `null` when the applicant wasn't asked (based on partner config). Always present. |
    
- **Employment Records** (array)
    
    
    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `employment_type` | Enum | No | `W2` or `GIG`. An empty string (`""`) when the payroll provider returned no employment details for the account; the four `w2_*`/`gig_*` fields are then omitted. |
    | `employer_information` | Object | No |  |
    |   ├ `employer_name` | String | Yes | `null` when the payroll provider returned no employment details. |
    |   ├ `employer_phone` | String | Yes |  |
    |   └ `employer_address` | Address (object) | Yes | Always `null`. Reserved for a future release. |
    | `employment_status` | String | Yes | The payroll provider's employment status, upper-cased. Usually `EMPLOYED`, `INACTIVE` or `TERMINATED`, but other provider values are passed through, so treat unrecognized values as unknown rather than rejecting them. |
    | `employment_start_date` | Date | Yes |  |
    | `employment_end_date` | Date | Yes | If the client is still employed, value will be `null`. |
    | `employee_information` | Object | No |  |
    |   ├ `first_name` | String | Yes | First name of client as reported by the payroll system. |
    |   ├ `last_name` | String | Yes | Last name of client as reported by the payroll system. |
    |   ├ `full_name` | String | Yes | Full name of client as in the payroll system. |
    |   └ `ssn` | String | Yes | Client SSN as reported by payroll system. Masked by default — last four digits only, format `XXX-XX-1234`. Partners may optionally have the full unmasked SSN enabled; this is off by default and requires discussion given the PII risk. The full SSN is available only when configured, and then only when available; other accounts in the same report still send the masked value. |
    | `pay_frequency` | Enum | Yes | Must be: `ANNUALLY`, `BIWEEKLY`, `DAILY`, `HOURLY`, `MONTHLY`, `QUARTERLY`, `SEMIMONTHLY`, `SEMIWEEKLY`, `VARIABLE`, `WEEKLY`. Null if the payroll aggregator does not report a pay frequency. |
    | `base_compensation` | Object | No | Always an object; its fields are `null` when no information is available. |
    |   ├ `rate` | Decimal | Yes | Wages in dollars |
    |   └ `interval` | Enum | Yes | Must be: `HOURLY`, `WEEKLY`, `MONTHLY`, `ANNUAL` or `SALARY`. `null` when the payroll provider reports no unit or one VMI doesn't map. |
    | `w2_monthly_summaries` | Array | Yes | If `employment_type` is `W2`, contains zero or more W2 Monthly Summary objects, otherwise `null` . |
    | `gig_monthly_summaries` | Array | Yes | If `employment_type` is `GIG`, contains zero or more Gig Monthly Summary objects, otherwise `null` . |
    | `w2_payments` | Array | Yes | If `employment_type` is `W2`, contains zero or more W2 Payment objects, otherwise `null` . |
    | `gig_payments` | Array | Yes | If `employment_type` is `GIG`, contains zero or more Gig Payment objects, otherwise `null` . |

    When `employment_type` is `""`, the four `w2_*`/`gig_*` fields above are omitted rather than `null`.

- **paystub_images_included** (Boolean) — top-level

    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `paystub_images_included` | Boolean | No | Top-level flag indicating whether a companion pay stub images file has been delivered with at least one actual pay stub image. `false` when the partner does not have pay stub images enabled. |

- **attachments** (object) — top-level, optional

    Present only when the partner has pay stub images enabled; omitted otherwise. Names the PDFs VMI delivers by the partner's SFTP or S3 transmission methods. On SFTP they are written to the same directory as `filenames.sftp`; on S3 they are inside the archive. Names only, with no directory.

    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `report_filename` | String | No | The income report PDF, e.g. `VMI_00012345_20260513_ConfABC123.pdf`. |
    | `paystubs_filename` | String | No | The pay stub images PDF, e.g. `VMI_00012345_20260513_ConfABC123_paystubs.pdf`. See `paystub_images_included` for whether it contains any images. |

- **Address (object)**
    
    Not currently sent (`employer_address` is always `null`); defined for a future release.
    
    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `line1` | String | Yes | Line one of address |
    | `line2` | String | Yes | Line two of address |
    | `city` | String | Yes | City of address |
    | `state` | String | Yes | State or territory the address is in |
    | `postal_code` | String | Yes | Postal code of address |
    | `country` | String | Yes | Country of Address. Defaults to ‘USA’ |
- **W2 Monthly Summary (object)**
    
    
    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `month` | Integer | No | Single digit representation of the month, 1 - 12 |
    | `year` | String | No | 4 digit year in `YYYY` format |
    | `total_hours` | Decimal | Yes | Total hours for the month as reported by payroll source. |
    | `number_of_paychecks` | Integer | No | Number of times paid in the month within the reporting window (90 or 182 days, per partner). |
    | `gross_income` | Decimal | No | Sum of incoming payment within the reporting window (90 or 182 days, per partner). |
    | `partial_month` | Boolean | No | ‘true’ if this month represents less than a full month |
    | `partial_month_start` | Date | Yes | Start of partial month period. Will be `null` if `partial_month` is `false`. When `partial_month` is `true`, contains the start date of the partial period. |
    | `partial_month_end` | Date | Yes | End of partial month period. Will be `null` if `partial_month` is `false`. When `partial_month` is `true`, contains the end date of the partial period. |
- **Gig Monthly Summary (object)**
    
    
    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `month` | Integer | No | Month the summary is for |
    | `year` | String | No | 4 digit year in `YYYY` format |
    | `total_hours` | Decimal | Yes | Total hours reports for the month. |
    | `gross_earnings` | Decimal | Yes | Sum of income payments for the month. |
    | `mileage_expenses` | Array | Yes | Always one entry per month, holding the month's total miles and the federal mileage rate for that month; `miles` is `null` when the payroll provider reports none.
    
    Verified mileage expenses can be calculated to cover costs including gas, car payments or leasing fees, car insurance, repairs, and maintenance.
     |
    |   ├ `rate` | Decimal | Yes | The IRS standard mileage rate for that month, in **dollars** per mile, to up to three decimal places (e.g. `0.725`). Multiply by `miles` for the verified mileage expense. `null` for a month with no gig activity. |
    |   └ `miles` | Decimal | Yes | Distance in miles. Converted from kilometers when the provider reports kilometers, and not rounded. |
- **W2 Payment (object)**
    
    
    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `pay_date` | Date | Yes |  |
    | `pay_period` | Object | Yes |  |
    |   ├ `start` | Date | Yes |  |
    |   └`end` | Date | Yes |  |
    | `gross_pay` | Decimal | No | If this value is not represented within pay stubs, a value of `0` will be sent. |
    | `net_pay` | Decimal | No | If this value is not represent within pay stubs, a value of `0` will be sent. |
    | `hours_worked` | Decimal | Yes | Hours on the pay stub. |
    | `base_hours_paid` | Decimal | Yes | Same value as `hours_worked`. Reserved for future use. |
    | `gross_pay_ytd` | Decimal | No | A `null` value will send as `0`. |
    | `gross_pay_line_items` | Array | No | Contains zero or more items listed on as part of the gross pay. |
    |   ├ `name` | String | Yes |  |
    |  └ `amount` | Decimal | No |  |
    |  `deductions` | Array | No | Contains zero or more items listed on as deductions. |
    |   ├ `name` | String | Yes |  |
    |   ├ `type` | Enum | No | Must be: `PRETAX` ,`POSTTAX` , or `UNKNOWN`  |
    |   └ `amount` | Decimal | Yes | `null` when the payroll provider didn't report an amount. |
    | `direct_deposit_accounts` | Array of String | No | Last 4 digits of the client's direct deposit (ACH) account numbers (fewer if the number is shorter). Off by default; sent as an empty array unless enabled for your integration, which enables `payout_card_accounts` too. Sent only when the payroll provider makes them available; otherwise empty even when enabled. |
    | `payout_card_accounts` | Array of String | No | Last 4 digits of the client's payout (pay) card numbers (fewer if the number is shorter). Enabled together with `direct_deposit_accounts`, with the same default, and likewise sent only when the payroll provider makes them available. |
- **Gig Payment (object)**
    
    
    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    |  `pay_date` | Date | Yes | `null` when the payroll provider didn't report the gig's end date. |
    |  `amount` | Decimal | Yes | `null` when the payroll provider didn't report an amount. |

### Sample Payload

A contract 2 ReportSubmission. Under contract 1 the body has no `event_type` and VMI also sends the `X-VMI-API-Key` header.

```jsx
POST /api/v1/income-report HTTP/1.1
Host: your-agency.gov
X-VMI-Timestamp: 1764709880
X-VMI-Signature: 77cdb11cfad51afd5b5d5eb8aa1b7735b1578202e479bf82eb36d38ac32c1f0263761fdc9c962e78a367d7e6bc841c8dbc97dcc5dc384cf0c4e36fe3ea3ec5e7
X-VMI-Confirmation-Code: LALDH00100001
Content-Type: application/json
Content-Length: 5648

{
  "event_type": "ReportSubmission",
  "report_metadata": {
    "confirmation_code": "LALDH00100001",
    "filenames": {
      "sftp": "CBVPilot_00012345_20260513_ConfLALDH00100001.pdf",
      "encrypted_s3": "CBVPilot_00012345_20260513_ConfLALDH00100001.tar.gz.gpg",
      "unencrypted_s3": "CBVPilot_00012345_20260513_ConfLALDH00100001.tar.gz"
    },
    "report_date_range": {
      "start_date": "2025-11-01",
      "end_date": "2026-02-01"
    },
    "consent_timestamp_utc": "2026-02-01T10:30:00Z"
  },
  "client_information": {
    "case_number": "CASE-998877",
    "first_name": "Elena",
    "last_name": "Thompson",
    "date_of_birth": "1992-11-20",
    "additional_jobs_to_report": true
  },
  "employment_records": [
    {
      "employment_type": "W2",
      "employer_information": {
        "employer_name": "General Hospital Systems",
        "employer_phone": "312-555-0456",
        "employer_address": null
      },
      "employment_status": "EMPLOYED",
      "employment_start_date": "2025-12-29",
      "employment_end_date": null,
      "employee_information": {
        "first_name": "Elena",
        "last_name": "Thompson",
        "full_name": "Elena Thompson",
        "ssn": "XXX-XX-4455"
      },
      "pay_frequency": "BIWEEKLY",
      "base_compensation": {
        "rate": 12.50,
        "interval": "HOURLY"
      },
      "gig_monthly_summaries": null,
      "w2_monthly_summaries": [
        {
          "month": 1,
          "year": "2026",
          "total_hours": 168.0,
          "number_of_paychecks": 2,
          "gross_income": 2440.00,
          "partial_month": false,
          "partial_month_start": null,
          "partial_month_end": null
        }
      ],
      "gig_payments": null,
      "w2_payments": [
        {
          "pay_date": "2026-01-09",
          "pay_period": {
            "start": "2025-12-29",
            "end": "2026-01-04"
          },
          "gross_pay": 1050.00,
          "net_pay": 843.16,
          "hours_worked": 80.0,
          "base_hours_paid": 80.0,
          "gross_pay_ytd": 1050.00,
          "gross_pay_line_items": [
            { "name": "Regular Pay (Hourly)", "amount": 850.00 },
            { "name": "Weekend - Premium", "amount": 28.92},
            { "name": "Weekend Prem Night Diff", "amount": 1.08},
            { "name": "Sick Time with shift", "amount": 50.00},
            { "name": "Paid Time Off - Misc", "amount": 100.00},
            { "name": "Imputed Income - Bravo Award", "amount": 20.00}
          ],
          "deductions": [
            { "name": "Medical", "type": "PRETAX", "amount": 50.00 },
            { "name": "401k", "type": "PRETAX", "amount": 25.00 }
          ],
          "direct_deposit_accounts": ["1234", "4567"],
          "payout_card_accounts": ["8910"]
        },
        {
          "pay_date": "2026-01-23",
          "pay_period": {
            "start": "2026-01-05",
            "end": "2026-01-18"
          },
          "gross_pay": 1390.00,
          "net_pay": 978.19,
          "hours_worked": 88.0,
          "base_hours_paid": 88.0,
          "gross_pay_ytd": 2440.00,
          "gross_pay_line_items": [
            { "name": "Regular", "amount": 1000.00 },
            { "name": "Overtime", "amount": 150.00 },
            { "name": "Tips", "amount": 10.00 },
            { "name": "Other", "amount": 230.00 }
          ],
          "deductions": [
            { "name": "Medical", "type": "PRETAX", "amount": 50.00 },
            { "name": "401k", "type": "PRETAX", "amount": 40.00 }
          ],
          "direct_deposit_accounts": [],
          "payout_card_accounts": []
        }
      ]
    },
    {
      "employment_type": "GIG",
      "employer_information": {
        "employer_name": "DoorDash",
        "employer_phone": null,
        "employer_address": null
      },
      "employment_status": "EMPLOYED",
      "employment_start_date": "2025-05-20",
      "employment_end_date": null,
      "employee_information": {
        "first_name": "Elena",
        "last_name": "Thompson",
        "full_name": "Elena Thompson",
        "ssn": "XXX-XX-4455"
      },
      "pay_frequency": "VARIABLE",
      "base_compensation": {
        "rate": null,
        "interval": null
      },
      "gig_monthly_summaries": [
        {
          "month": 12,
          "year": "2025",
          "total_hours": 128.50,
          "gross_earnings": 1336.45,
          "mileage_expenses": [
            { "miles": 942, "rate": 0.7 }
          ]
        },
        {
          "month": 1,
          "year": "2026",
          "total_hours": 45.20,
          "gross_earnings": 620.75,
          "mileage_expenses": [
            { "miles": 310.4, "rate": 0.725 }
          ]
        }
      ],
      "w2_monthly_summaries": null,
      "gig_payments": [
        { "pay_date": "2026-01-26", "amount": 340.25 },
        { "pay_date": "2026-01-19", "amount": 280.50 },
        { "pay_date": "2025-12-29", "amount": 315.10 },
        { "pay_date": "2025-12-22", "amount": 420.75 },
        { "pay_date": "2025-12-15", "amount": 290.40 },
        { "pay_date": "2025-12-08", "amount": 310.20 }
      ],
      "w2_payments": null
    }
  ],
  "paystub_images_included": true,
  "attachments": {
    "report_filename": "CBVPilot_00012345_20260513_ConfLALDH00100001.pdf",
    "paystubs_filename": "CBVPilot_00012345_20260513_ConfLALDH00100001_paystubs.pdf"
  }
}
```

## TransmissionComplete Event

Sent under contract 2 only, to the same endpoint and with the same headers and signing as a ReportSubmission.

When VMI delivers a submission by other transmission methods as well as this webhook (for example SFTP or S3), it sends one `TransmissionComplete` per method once that method's delivery has finished. For file-producing methods, the file at `uri` exists by then and can be fetched without polling.

| **Field Name** | **Type** | **Nullable?** | **Description** |
| --- | --- | --- | --- |
| `event_type` | Enum | No | `TransmissionComplete` |
| `confirmation_code` | String | No | Matches `report_metadata.confirmation_code` in the ReportSubmission for the same submission, and the `X-VMI-Confirmation-Code` header. |
| `transmission_method` | String | No | The method that finished delivering: `sftp`, `encrypted_s3`, `unencrypted_s3`, `shared_email` or `json`. Receivers should accept values they don't recognize. |
| `uri` | String | Yes | The same value as `report_metadata.filenames[transmission_method]` in the ReportSubmission: the SFTP path or S3 object key of the delivered file. Always present; `null` for methods that don't produce a file (`shared_email`, `json`). |
| `completed_at` | DateTime | No | When the delivery finished. |

Notes:

- No `TransmissionComplete` is sent for the webhook itself. The partner's 2xx response to the ReportSubmission is its completion.
- For SFTP with pay stub images enabled, the pay stub images PDF is delivered in the same step and to the same folder as `uri`, with `_paystubs` added before the extension (e.g. `CBVPilot_00012345_20260513_ConfLALDH00100001_paystubs.pdf`).
- Events are delivered independently. A `TransmissionComplete` can arrive before the ReportSubmission it relates to; correlate on `confirmation_code`.
- An event may be delivered more than once, for example when a 2xx response is lost and VMI retries. Make processing idempotent; `confirmation_code` + `transmission_method` identifies a `TransmissionComplete`.
- In rare failure cases a `TransmissionComplete` may not be delivered. The ReportSubmission's `filenames` remain the record of which files to expect.

### Sample TransmissionComplete

```jsx
POST /api/v1/income-report HTTP/1.1
Host: your-agency.gov
X-VMI-Timestamp: 1764709940
X-VMI-Signature: <hex HMAC-SHA512 of "1764709940:<body>">
X-VMI-Confirmation-Code: LALDH00100001
Content-Type: application/json

{
  "event_type": "TransmissionComplete",
  "confirmation_code": "LALDH00100001",
  "transmission_method": "sftp",
  "uri": "CBVPilot_00012345_20260513_ConfLALDH00100001.pdf",
  "completed_at": "2026-05-13T18:04:11Z"
}
```

## Error Handling and Retry Logic

VMI relies on semantic HTTP status codes to determine if the data was correctly received.

### Status Codes

| **HTTP Status Code** | **Definition** | **VMI action** |
| --- | --- | --- |
| **2xx** (e.g. **200 OK**) | The data was successfully received and ingested. | Mark delivered. Any 2xx status counts as success. |
|  |  |  |
| **400 Bad Request** | The data in the body is malformed or fails schema validation, or the body's confirmation code doesn't match `X-VMI-Confirmation-Code`. | Don't retry. Record the delivery as failed and alert the VMI team. |
| **401 Unauthorized** | X-VMI-Signature verification failed, a required header is missing, or `X-VMI-Timestamp` is too far from the receiver's clock. | Retry. |
| **413 Payload Too Large** | Content-Length exceeds partner server size limit. | Don't retry. Record the delivery as failed and alert the VMI team. |
| **422 Unprocessable Entity** | The request was understood but can't be processed. | Don't retry. Record the delivery as failed and alert the VMI team. |
| **429 Too Many Requests** | Rate of requests is exceeding partner server limits. | Retry. |
|  |  |  |
| **500 Internal Error** | System error during processing. | Retry. |
| **503 Service Unavailable** | The partner server is temporarily unavailable or undergoing maintenance. | Retry. |
| **504 Gateway Timeout** | Communication error between application and partner server. | Retry. |
| **Anything else** | Any other status (including 3xx redirects, which VMI doesn't follow, and 404), a connection failure, or no response within 60 seconds. | Retry. |

A ReportSubmission and each TransmissionComplete are delivered, and retried, independently.

Partners are encouraged to use additional codes or include descriptive error messages to assist in troubleshooting. 

Respond 2xx to an `event_type` the receiver doesn't recognize, so that new VMI event types don't cause failed deliveries.

Example descriptive error message:

```json
{
  "error_code": "VALIDATION_ERROR",
  "message": "The request was well-formed but contains errors.",
  "errors": [
    {
      "field": "gross_pay",
      "reason": "Value must be a positive decimal."
    },
    {
      "field": "case_number",
      "reason": "This field is required."
    }
  ]
}
```

### Retry Logic

When a response calls for a retry, the VMI platform will:

- Make up to **five attempts in total** (the first delivery and four retries), about **75 seconds apart**, so retries end roughly five minutes after the first attempt.
- Sign each attempt afresh, with a new `X-VMI-Timestamp`.
- Move the event to an **error queue** for the VMI team to inspect if the final attempt fails. Events can be resent from there.

Responses that VMI doesn't retry (400, 413 and 422) aren't queued: VMI records the failure and alerts the VMI team.

Because retries end within minutes, tell the VMI team about planned downtime longer than that, so events that reach the error queue during it can be resent afterwards.