# Webhooks Data Transmission Spec v1

| **Date** | **Revision Note** |
| --- | --- |
| 2/9/2026 | Initial document created |
| 3/10/2026 | Update partial_month documentation and add partial_month_start and partial_month_end |
| 3/12/2026 | Update month to be integer instead of 3 letter code |
| 3/27/2026 | Make pay_frequency nullable, fix sample payload pay_period fields, add deductions nullable, clarify partial_month fields |

# Introduction

This document outlines the API specification implemented by partners to receive structured JSON representations of income verification data from the Verify My Income platform. 

The partner must build this API endpoint and ensure that data is ingested into the correct case within the eligibility management system.

# Environments

The partner must provide two distinct endpoints to the VMI team. Each environment will utilize unique API keys.

| **Environment Name** | **VMI Environment** | **Sample Path** |
| --- | --- | --- |
| UAT | Demo | `https://uat.your-agency.gov/api/v1/income-report`  |
| Production | Production | `https://your-agency.gov/api/v1/income-report`  |

# API Specification

## Receive income report: POST /api/v1/income-report

- **Method**: `POST`
- **Path**: `/api/v1/income-report`
- **Security:** The endpoint must only accept requests over TLS.
- **Authentication**: The partner will supply an API key GUID that will be sent along with all requests as a header.

This API endpoint must be built by the partner and will receive an income report as structured JSON data. The partner can suggest an alternative path as long as it contains a version number. 

### Versioning Policy

VMI uses semantic versioning in the API path (e.g., /v1/).

Minor Changes: (e.g. adding optional fields) will be done within the current version.

Major Changes: (e.g. removing required fields or changing data types) will result in a new version (e.g., /v2/). 

Partners are expected to build "flexible" parsers that do not fail when encountering new, unrecognized JSON keys.

### Request Headers

The following headers are required for every transmission to ensure security and message integrity.

| Header | Description |
| --- | --- |
| `X-VMI-Timestamp` | Seconds since the Unix epoch (used to verify the request signature). |
| `X-VMI-Signature` | Calculated signature based on the request body. |
| `X-VMI-Confirmation-Code` | Unique confirmation code of the submitted record (e.g., "LALDH00100001"). |
| `X-VMI-API-Key` | Unique secure GUID provided by the partner. |
| `Content-Type` | Must be `application/json`. |
| `Content-Length` | Number of bytes in the body.  |

Additional headers used for authentication may be requested by the partner.

### Request Body

The request body contains the income data. This payload is formatted as a JSON object to allow for direct field mapping into the eligibility management system.

**Data Types**

- **Date:** String in `YYYY-MM-DD` format (ISO-8601).
- **DateTime:** String in `YYYY-MM-DDTHH:MM:SSZ` format (ISO-8601 UTC).
- **Decimal:** Number with two decimal places.
- **Enum:** A string that must match a specific set of allowed values.

- **Report Metadata** (object)
    
    
    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `confirmation_code` | String | No | Unique confirmation code of the submitted record. |
    | `report_date_range` | Object | No |  |
    |   ├ `start_date` | Date | No | Earliest date of review period  |
    |   └  `end_date` | Date | No | Last date of review period  |
    | `consent_timestamp_utc` | DateTime | No | Date and time when client provided legal consent for data retrieval. |

- **Client Information** (object) - Varies by partner
    
    This object contains unique identifying information to link the report to the correct record in the partner’s eligibility database. These fields (e.g. `case_number`, `last_name`) will be agreed upon with each partner. 
    
- **Employment Records** (array)
    
    
    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `employment_type` | Enum | No | Must be: `W2` or `GIG` |
    | `employer_information` | Object | No |  |
    |   ├ `employer_name` | String | No |  |
    |   ├ `employer_phone` | String | Yes |  |
    |   └ `employer_address` | Address (object) | Yes |  |
    | `employment_status` | Enum | Yes | Must be:`EMPLOYED` ,`ACTIVE` ,`INACTIVE`, `TERMINATED` |
    | `employment_start_date` | Date | Yes |  |
    | `employment_end_date` | Date | Yes | If the client is still employed, value will be `null`. |
    | `employee_information` | Object | No |  |
    |   ├ `full_name` | String | Yes | Full name of client as in the payroll system. |
    |   └ `ssn` | String | Yes | Last four digits of client SSN as reported by payroll system. 
    Format: `XXX-XX-1234` |
    | `pay_frequency` | Enum | Yes | Must be: `ANNUALLY`, `BIWEEKLY`, `DAILY`, `HOURLY`, `MONTHLY`, `QUARTERLY`, `SEMIMONTHLY`, `SEMIWEEKLY`, `VARIABLE`, `WEEKLY`. Null if the payroll aggregator does not report a pay frequency. |
    | `base_compensation` | Object | Yes | If no information is available, this value is `null`. |
    |   ├ `rate` | Decimal | Yes | Wages in dollars |
    |   └ `interval` | Enum | Yes | Must be: `HOURLY`, `DAILY`, `WEEKLY`, `BIWEEKLY`, `SEMIMONTHLY`, `MONTHLY`, `ANNUAL` , `SALARY` |
    | `w2_monthly_summaries` | Array | Yes | If `employment_type` is `W2`, contains zero or more W2 Monthly Summary objects, otherwise `null` . |
    | `gig_monthly_summaries` | Array | Yes | If `employment_type` is `GIG`, contains zero or more Gig Monthly Summary objects, otherwise `null` . |
    | `w2_payments` | Array | Yes | If `employment_type` is `W2`, contains zero or more W2 Payment objects, otherwise `null` . |
    | `gig_payments` | Array | Yes | If `employment_type` is `GIG`, contains zero or more Gig Payment objects, otherwise `null` . |

- **Address (object)**
    
    
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
    | `number_of_paychecks` | Integer | No | Number of times paid in the month within the 90-day reporting window. |
    | `gross_income` | Decimal | No | Sum of incoming payment within the 90-day reporting window. |
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
    | `mileage_expenses` | Array | Yes | For certain `GIG` employments only, variable depending on `GIG` type.
    
    Verified mileage expenses can be calculated to cover costs including gas, car payments or leasing fees, car insurance, repairs, and maintenance.
     |
    |   ├ `rate` | Decimal | Yes | IRS-defined deduction rate per mile in **cents**. |
    |   └ `miles` | Decimal | Yes | Distance in miles. |
- **W2 Payment (object)**
    
    
    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    | `pay_date` | Date | Yes |  |
    | `pay_period` | Object | Yes |  |
    |   ├ `start` | Date | Yes |  |
    |   └`end` | Date | Yes |  |
    | `gross_pay` | Decimal | No | If this value is not represented within pay stubs, a value of `0` will be sent. |
    | `net_pay` | Decimal | No | If this value is not represent within pay stubs, a value of `0` will be sent. |
    | `hours_worked` | Decimal | Yes |  |
    | `base_hours_paid` | Decimal | Yes |  |
    | `gross_pay_ytd` | Decimal | No | A `null` value will send as `0`. |
    | `gross_pay_line_items` | Array | No | Contains zero or more items listed on as part of the gross pay. |
    |   ├ `name` | String | Yes |  |
    |  └ `amount` | Decimal | No |  |
    |  `deductions` | Array | No | Contains zero or more items listed on as deductions. |
    |   ├ `name` | String | Yes |  |
    |   ├ `type` | Enum | No | Must be: `PRETAX` ,`POSTTAX` , or `UNKNOWN`  |
    |   └ `amount` | Decimal | No |  |
- **Gig Payment (object)**
    
    
    | **Field Name** | **Type** | **Nullable?** | **Description** |
    | --- | --- | --- | --- |
    |  `pay_date` | Date | No |  |
    |  `amount` | Decimal | No |  |

### Sample Payload

```jsx
POST /api/v1/income-report HTTP/1.1
Host: your-agency.gov
X-VMI-Timestamp: 1764709880
X-VMI-Signature: 77cdb11cfad51afd5b5d5eb8aa1b7735b1578202e479bf82eb36d38ac32c1f0263761fdc9c962e78a367d7e6bc841c8dbc97dcc5dc384cf0c4e36fe3ea3ec5e7
X-VMI-API-Key: abc123_example_key
X-VMI-Confirmation-Code: LALDH00100001
Content-Type: application/json
Content-Length: 5648

{
  "report_metadata": {
    "confirmation_code": "LALDH00100001",
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
        "employer_address": {
          "line1": "710 N Fairbanks Ct",
          "line2": "Floor 4",
          "city": "Chicago",
          "state": "IL",
          "postal_code": "60611",
          "country": "United States"
        }
      },
      "employment_status": "EMPLOYED",
      "employment_start_date": "2025-12-29",
      "employment_end_date": null,
      "employee_information": {
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
          "gross_income": 2590.00,
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
          ]
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
          "base_hours_paid": 80.0,
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
          ]
        }
      ]
    },
    {
      "employment_type": "GIG",
      "employer_information": {
        "employer_name": "DoorDash",
        "employer_phone": null,
        "employer_address": {
          "line1": "303 2nd St",
          "line2": "South Tower",
          "city": "San Francisco",
          "state": "CA",
          "postal_code": "94107",
          "country": "United States"
        }
      },
      "employment_status": "ACTIVE",
      "employment_start_date": "2025-05-20",
      "employment_end_date": null,
      "employee_information": {
        "full_name": "Elena Thompson",
        "ssn": "XXX-XX-4455"
      },
      "pay_frequency": "VARIABLE",
      "base_compensation": null,
      "gig_monthly_summaries": [
		    {
		      "month": 12,
		      "year": "2025",
		      "total_hours": 128.50,
		      "gross_earnings": 1336.45,
		      "mileage_expenses": [
		        { "rate": 70.0, "miles": 942 }
		      ]
		    }, 
        {
          "month": 1,
          "year": "2026",
          "total_hours": 45.20,
          "gross_earnings": 620.75,
          "mileage_expenses": [
            { "rate": 72.5, "miles": 310.4 }
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
  ]
}
```

## Error Handling and Retry Logic

VMI relies on semantic HTTP status codes to determine if the data was correctly received.

### Status Codes

| **HTTP Status Code** | **Definition** | **Action** |
| --- | --- | --- |
| **200 OK** | The data was successfully received and ingested. | Mark successful. |
|  |  |  |
| **400 Bad Request** | The data in the body is malformed or fails schema validation. | Send to error queue. |
| **401 Unauthorized** | The X-VMI-Signature header or API key verification failed. | Attempt retry. |
| **413 Payload Too Large** | Content-Length exceeds partner server size limit. | Send to error queue. |
| **422 Unprocessable Entity** |  | Send to error queue. |
| **429 Too Many Requests** | Rate of requests is exceeding partner server limits. | Attempt retry. |
|  |  |  |
| **500 Internal Error** | System error during processing. | Attempt retry. |
| **503 Service Unavailable** | The partner server is temporarily unavailable or undergoing maintenance. | Attempt retry. |
| **504 Gateway Timeout** | Communication error between application and partner server. | Attempt retry. |

Partners are encouraged to use additional codes or include descriptive error messages to assist in troubleshooting. 

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

If a non-success status code is returned, the VMI platform will:

- Automatically retry delivery up to **five additional times**.
- Conduct retries over a **10-minute window**.
- Move the record to an **error queue** for further inspection if the final attempt fails.