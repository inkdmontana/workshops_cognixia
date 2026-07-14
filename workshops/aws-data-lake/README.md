# AWS Data Lake Workshop: Hands-On Labs

A hands-on AWS data lake workshop covering **Amazon S3**, **AWS Glue**, **Amazon Athena**,
**AWS Lake Formation**, **Amazon Redshift Serverless**, **AWS Database Migration Service (DMS)**,
and **Amazon OpenSearch Service**: building a production-style data lake end to end, from raw
ingestion through governance, change data capture (CDC), and analytics.

Designed for **data engineers, cloud engineers, and solutions architects** building real-world
AWS data platform skills through instructor-led, console- and CLI-driven labs: not slides.

---

## Before you start

**Your instructor will provide:**
- AWS Console URL, username, and temporary password
- Region: **us-west-2** (all labs are locked to this region)
- Your username slug (`<USER>`): everything before the `@` in your login

**Naming rule: read this once, apply it everywhere:**
Every resource you create must be prefixed `quicklabs-<USER>-` (or `quicklabs_<USER>_` with underscores for Glue databases). Your IAM policy only allows actions on resources in your own namespace. A typo here produces `not authorized` errors.

**Tagging rule: apply to every resource you create:**

| Key | Value |
|---|---|
| `workshop` | `data-lake` |
| `autodelete` | `true` or `false` |
| `date` | `dd-mmm-yyyy`, e.g. `12-Jul-2026` |

`autodelete=true` means it's safe for the instructor's cleanup script to delete it at the end of the batch. Use `autodelete=false` only for something you were explicitly told to keep.

**Local tools you need:**
- `psql`: for CDC and Redshift labs (`brew install libpq` on macOS, `apt install postgresql-client` on Linux)
- AWS CLI: optional but useful for verifying resources

---

## Workshop labs

| Lab | AWS services covered | Lab guide |
|---|---|---|
| Lab 1 | **Amazon S3** · **AWS Glue** Crawler & ETL (PySpark) · **Amazon Athena** | [console-lab-glue-athena.md](lab-1-data-lake/console-lab-glue-athena.md) · [cli version](lab-1-data-lake/cli-lab-glue-athena.md) |
| Lab 2 | Event-driven ingestion: **Amazon S3** → **Amazon SQS** → **AWS Lambda** | [console-lab-lambda-ingestion.md](lab-2-lambda-ingestion/console-lab-lambda-ingestion.md) |
| Lab 3 | **AWS Lake Formation**: row/column/tag-based access control | [lakeformation-console-demo.md](lab-3-lake-formation/lakeformation-console-demo.md) |
| Lab 4 | **Amazon Redshift Serverless** · federated query from RDS | [console-lab-redshift-federated-query.md](lab-4-redshift-serverless/console-lab-redshift-federated-query.md) |
| Lab 5 | Change data capture (CDC): PostgreSQL → **AWS Database Migration Service (DMS)** → S3 or PostgreSQL target | [console-lab-cdc-dms-postgres.md](lab-5-cdc/console-lab-cdc-dms-postgres.md) |
| Lab 6 | **Amazon OpenSearch Service**: ingestion, search, and dashboards | [student-lab-6-opensearch.md](lab-6-opensearch/student-lab-6-opensearch.md) |

Labs 1–3 build on each other. Labs 4–6 are standalone and can be done in any order after Lab 1.

---

## Datasets and scripts

| File | Used in | How to get it |
|---|---|---|
| `Crude_Oil_historical_data.csv` | Labs 1, 4, 5 | Link provided by your instructor |
| `oil_csv_to_parquet.py` | Lab 1 (Glue ETL job) | [`lab-1-data-lake/oil_csv_to_parquet.py`](lab-1-data-lake/oil_csv_to_parquet.py) |

---

## Getting help

- Each lab guide has a **Troubleshooting reference** table at the end: check there first.
- `not authorized` errors almost always mean a naming typo: verify your `<USER>` slug and the resource name match exactly.
- Ask your instructor if you're stuck for more than a few minutes; don't lose session time.
