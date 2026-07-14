# Student Lab: Oracle CDC via AWS DMS (Oracle target or S3 target)

End-to-end student lab: provision your own Oracle on RDS, load an HR
`EMPLOYEES` table into it, and capture every INSERT/UPDATE/DELETE in real time
via AWS DMS. The lab supports **two target options**: pick one based on what
you want to learn:

| | Option A: Oracle target | Option B: S3 target |
|---|---|---|
| **Target** | Second RDS Oracle instance | S3 bucket (CSV files) |
| **Migration type** | Migrate and replicate (full load + CDC) | Replicate data changes only (CDC only) |
| **Best for** | Understanding Oracle-to-Oracle replication, homogeneous lift-and-shift migrations | Understanding how CDC feeds a data lake, I/U/D file format |
| **Screenshots** | Not yet captured for this lab: follow the field tables below | Not yet captured for this lab: follow the field tables below |

**This lab requires temporary admin access** to your AWS account (the
instructor will grant it for the session). RDS parameter groups aren't
needed for Oracle the way they are for Postgres, but DMS replication
instances, IAM service roles, and RDS instance modification (backup
retention) all need permissions beyond the standard `quicklabs-student<U>`
policies.

Replace `<U>` throughout with your username digit (e.g. `8` for
`quicklabs-student8`).

---

## What you'll build

```
  ┌─────────────────────┐    redo log (LogMiner)  ┌──────────────────────┐
  │ RDS Oracle           │ ─────────────────────▶ │ DMS replication      │
  │ hr-db-<U>            │  (supplemental logging) │ instance             │
  │ ADMIN.EMPLOYEES      │                        │ hr-cdc-rep-<U>       │
  └─────────────────────┘                         └──────┬───────┬───────┘
              ▲                                          │       │
              │ INSERT / UPDATE / DELETE                 │       │
              │ (you, via SQL client)                    │       │
                                           ┌──────────────┘       └─────────────┐
                                           ▼                                    ▼
                               ┌──────────────────────┐      ┌──────────────────────┐
                               │ Option A             │      │ Option B             │
                               │ RDS Oracle target    │      │ S3 target            │
                               │ hr_target schema     │      │ s3://quicklabs-      │
                               │ EMPLOYEES            │      │ student<U>-curated/  │
                               │ (full load + CDC)    │      │ cdc-oracle/ (CDC-only)│
                               └──────────────────────┘      └──────────────────────┘
```

By the end you'll have:

- Your own RDS Oracle source with a 20-row `EMPLOYEES` table
- A working DMS pipeline replicating to **either** a second Oracle RDS instance (Option A) or an S3 bucket (Option B)
- A clear understanding of the gotchas: ARCHIVELOG mode, supplemental logging, schema-scoped table mappings, and S3 IAM permissions

---

## Prerequisites

- **Temp admin access granted** (your instructor attaches `AdministratorAccess` to your IAM user for this session)
- AWS console as `quicklabs-student<U>` in **us-west-2** (don't switch regions)
- Sign out and sign back in after admin access is attached, so your session picks up the new policy
- An Oracle SQL client: SQL Developer, SQL*Plus (needs Oracle Instant Client), **or** `python-oracledb` in thin mode (`pip install oracledb`) if you don't have Instant Client installed: thin mode needs no separate client library at all
- Repo cloned locally: you'll use the loader script from `lab-5-cdc/oracle-source/`

---

## Part 1: Create your RDS Oracle source (15 min)

### 1.1 Create the RDS instance

**RDS console → Databases → Create database**

| Field | Value |
|---|---|
| Creation method | Standard create |
| Engine | Oracle |
| Edition | Oracle Enterprise Edition (or whichever edition your account is licensed/eligible for) |
| Templates | Free tier (or Dev/Test) |
| DB instance identifier | `hr-db-<U>` |
| Master username | `admin` |
| Master password | pick a strong one, write it down |
| DB instance class | `db.t3.micro` or smallest available for Oracle in your account |
| Storage | 20 GB gp3, no autoscaling |
| Public access | **Yes** |
| VPC security group | Create new → `hr-db-sg-<U>` |
| Initial database name | `ORCL` |
| **Backup retention period** | **7 days: this is required, not optional** (see 1.3) |

Click **Create database**. Provisioning takes 10–15 minutes for Oracle (longer than Postgres).

### 1.2 Edit the security group inbound rules

While RDS provisions, **EC2 console → Security Groups → `hr-db-sg-<U>` → Edit inbound rules**. Add two rules:

| Type | Protocol | Port | Source | Why |
|---|---|---|---|---|
| Oracle-RDS | TCP | 1521 | My IP | Your laptop's SQL client access |
| Oracle-RDS | TCP | 1521 | **The SG itself** (`sg-...`) | So the DMS replication instance can reach Oracle |

### 1.3 Why backup retention matters: ARCHIVELOG mode

Unlike self-managed Oracle, **RDS Oracle has no direct `ALTER DATABASE ARCHIVELOG` command**:
ARCHIVELOG mode is controlled entirely by the backup retention period. Setting it to 7 days at
creation (step 1.1) already enables it. Verify once the instance is available:

```sql
SELECT log_mode FROM v$database;
-- must return: ARCHIVELOG
```

If you skipped this at creation, fix it now: it will not take effect until the instance
finishes applying the change:

```bash
aws rds modify-db-instance \
  --db-instance-identifier hr-db-<U> \
  --backup-retention-period 7 \
  --apply-immediately
aws rds wait db-instance-available --db-instance-identifier hr-db-<U>
```

### 1.4 Enable supplemental logging

DMS CDC on Oracle also requires minimal + primary-key supplemental logging at the database
level. RDS blocks the direct SQL command (`ALTER DATABASE ADD SUPPLEMENTAL LOG DATA`) because it
requires SYSDBA, which RDS withholds even from the `admin` master user. Use the RDS-specific
package instead: connect with your SQL client as `admin` and run:

```sql
exec rdsadmin.rdsadmin_util.alter_supplemental_logging('ADD');
exec rdsadmin.rdsadmin_util.alter_supplemental_logging('ADD','PRIMARY KEY');

SELECT supplemental_log_data_min FROM v$database;
-- must return: YES or IMPLICIT
```

**If `sqlplus`/Oracle Instant Client isn't working on your machine**, use the provided
`oracle-source/enable_supplemental_logging.py` script instead: it uses `python-oracledb` in
thin mode, which needs no Oracle client install at all:

```bash
pip install oracledb
python3 oracle-source/enable_supplemental_logging.py
```
It will prompt for your `admin` password (never hardcode it in the script) and print the
before/after `supplemental_log_data_min` value.

---

## Part 2: Load the EMPLOYEES data (3 min)

```sql
-- run oracle-source/employees_schema.sql in your SQL client, connected as admin
```

This creates the `EMPLOYEES` table (20 rows, a Plant-Manager-down hierarchy via a
self-referencing `MANAGER_ID` foreign key) under the `ADMIN` schema.

Verify:
```sql
SELECT COUNT(*) FROM EMPLOYEES;  -- expect 20
SELECT owner FROM all_tables WHERE table_name = 'EMPLOYEES';  -- expect ADMIN
```

---

## Part 3: DMS S3-writer IAM role (Option B only: 5 min)

> **Skip this part if you chose Option A (Oracle target).** Go straight to Part 4.

DMS needs an IAM role with write access to your S3 bucket. **You don't have
to create this manually**: when you configure the S3 target endpoint in
Part 5.2 Option B, the DMS console offers a **"Create new IAM role"** link. Use that
if it's available to your account.

If you'd rather pre-create the role, here's the manual path: and note the two
permissions that are easy to miss and will cause a table to load partially, then
suspend with a vague "Handling new table failed" error:

<details>
<summary><b>Manual creation (optional)</b></summary>

**IAM console → Roles → Create role**

| Field | Value |
|---|---|
| Trusted entity type | AWS service |
| Use case | **DMS** |
| Role name | `dms-cdc-s3-role-oracle-<U>` |

Skip the AWS-managed policies dropdown, click Next → **Create role**.

Open the role → **Add permissions → Create inline policy** → JSON tab:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:PutObjectTagging",
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ],
    "Resource": [
      "arn:aws:s3:::quicklabs-student<U>-curated",
      "arn:aws:s3:::quicklabs-student<U>-curated/*"
    ]
  }]
}
```

**`s3:DeleteObject` and `s3:PutObjectTagging` are the two everyone forgets.** DMS
manages the lifecycle of the files it writes (including during CDC), and without
these two actions a table will look like it's loading fine: then suspend partway
through with an error that gives no hint it's a permissions problem. The actual
`AccessDenied` only shows up buried in the task's detailed logs.

Save as `dms-s3-inline`. Then in Part 5.2 use this role ARN directly
instead of clicking "Create new IAM role."

</details>

---

## Part 4: Create the DMS replication instance (10 min)

**DMS console → Replication instances → Create replication instance**

| Field | Value |
|---|---|
| Name | `hr-cdc-rep-<U>` |
| Instance class | `dms.t3.micro` (cheapest, free tier eligible) |
| Engine version | latest |
| Allocated storage | 20 GB |
| VPC | **same VPC as your RDS** |
| Multi-AZ | dev or non-prod (single AZ) |
| Publicly accessible | **No** |

Provisioning takes ~5 minutes. Move on to the endpoints while it provisions.

---

## Part 5: Create the source and target endpoints (5 min)

### 5.1 Source endpoint (Oracle)

**DMS console → Endpoints → Create endpoint**

| Field | Value |
|---|---|
| Endpoint type | **Source** |
| Endpoint identifier | `hr-source-oracle-<U>` |
| Source engine | Oracle |
| Server name | your RDS endpoint (e.g. `hr-db-<U>.xxx.us-west-2.rds.amazonaws.com`) |
| Port | 1521 |
| SID / Service name | `ORCL` |
| User name | `admin` |
| Password | your password |

**Test connection** (pick `hr-cdc-rep-<U>` as the rig). Must say "Successfully connected" before continuing.

**Common error here:** if the premigration assessment later fails on "Minimum Supplemental
Logging" or ARCHIVELOG mode, go back to Part 1.3/1.4: those checks are catching a real
structural requirement, not a formality. Don't try to bypass the assessment; fix the underlying
setting instead.

### 5.2 Target endpoint: choose your option

---

#### Option A: Oracle RDS target

Create a second RDS Oracle instance to receive the replicated data (repeat Part 1.1, naming it
`hr-target-<U>`), then point DMS at it.

**DMS console → Endpoints → Create endpoint**

| Field | Value |
|---|---|
| Endpoint type | **Target** |
| Endpoint identifier | `hr-target-oracle-<U>` |
| Target engine | **Oracle** |
| Server name | your *target* RDS endpoint |
| Port | 1521 |
| SID / Service name | `ORCL` |
| User name | `admin` |
| Password | your password |

**Test connection** against `hr-cdc-rep-<U>`. Must say "Successfully connected".

---

#### Option B: S3 target

**DMS console → Endpoints → Create endpoint**

| Field | Value |
|---|---|
| Endpoint type | **Target** |
| Endpoint identifier | `hr-target-s3-<U>` |
| Target engine | **Amazon S3** |
| IAM role ARN | Click **"Create new IAM role"**, or paste the ARN of `dms-cdc-s3-role-oracle-<U>` if you pre-created it in Part 3 |
| Bucket name | `quicklabs-student<U>-curated` |
| Bucket folder | `cdc-oracle` |

**Endpoint settings → Wizard mode:**

| Setting | Value |
|---|---|
| `dataFormat` | `csv` |
| `includeOpForFullLoad` | `true` |
| `cdcInsertsAndUpdates` | `true` |
| `timestampColumnName` | `cdc_ts` |

**Test connection.** Must pass.

---

## Part 6: Create the CDC task (3 min)

**DMS console → Database migration tasks → Create task**

| Field | Option A (Oracle target) | Option B (S3 target) |
|---|---|---|
| Task identifier | `hr-cdc-task-<U>` | `hr-cdc-task-<U>` |
| Replication instance | `hr-cdc-rep-<U>` | `hr-cdc-rep-<U>` |
| Source endpoint | `hr-source-oracle-<U>` | `hr-source-oracle-<U>` |
| Target endpoint | `hr-target-oracle-<U>` | `hr-target-s3-<U>` |
| **Migration type** | **Migrate and replicate** (full load + CDC) | **Replicate data changes only** (CDC only) |
| Start task on create | **Yes** | **Yes** |
| Table mappings (Wizard) | Schema `ADMIN`, table `EMPLOYEES`, **Include** | Schema `ADMIN`, table `EMPLOYEES`, **Include** |

**Do not use a wildcard schema (`%`) here.** Oracle databases: including RDS: contain
internal system schemas like `GSMADMIN_INTERNAL`. A wildcard selection rule will make DMS try
to migrate those too, and they'll fail as an unrelated "Table error" that has nothing to do
with your actual data. Scope explicitly to `ADMIN`.

If editing the table mapping as JSON instead of the wizard:
```json
{
  "rules": [
    {
      "rule-type": "selection",
      "rule-id": "1",
      "rule-name": "1",
      "object-locator": {
        "schema-name": "ADMIN",
        "table-name": "EMPLOYEES"
      },
      "rule-action": "include"
    }
  ]
}
```

Click **Create task**. Wait ~30-60 seconds. Status should move from `Creating` → `Starting` →
`Replication ongoing`.

If a table shows **Table error** in Table statistics, click into that row for the specific
error text: the summary status never tells you *why*, only that it happened. Check
CloudWatch Logs (turn on `EnableLogging` in the task's Logging settings) if the console detail
view isn't enough.

---

## Part 7: Verify the migration and watch CDC in action (5 min)

Run these against the **source** database (`ADMIN.EMPLOYEES`), connected as `admin`:

```sql
-- 7.1 Give someone a raise
UPDATE EMPLOYEES SET SALARY = SALARY + 1000 WHERE EMPLOYEE_ID = 1001;
COMMIT;

-- 7.2 Add a new hire
INSERT INTO EMPLOYEES (EMPLOYEE_ID, FIRST_NAME, LAST_NAME, EMAIL, PHONE_NUMBER, HIRE_DATE, JOB_TITLE, DEPARTMENT, SALARY, MANAGER_ID, PLANT_LOCATION)
VALUES (1021, 'Jordan', 'Reyes', 'jordan.reyes@example.com', '316-555-0130', SYSDATE, 'Quality Inspector', 'Quality Assurance', 66000, 1003, 'Wichita KS');
COMMIT;

-- 7.3 Someone leaves
DELETE FROM EMPLOYEES WHERE EMPLOYEE_ID = 1021;
COMMIT;
```

---

### Option A: Verify in the Oracle target

Connect to the target instance and confirm the full load landed and changes replicated:

```sql
SELECT COUNT(*) FROM EMPLOYEES;  -- expect 20 (net of the insert+delete test above)
SELECT EMPLOYEE_ID, SALARY FROM EMPLOYEES WHERE EMPLOYEE_ID = 1001;  -- expect the +1000 raise
```

---

### Option B: Verify in S3

Open two windows:

- **S3 console** → `quicklabs-student<U>-curated` → `cdc-oracle/` folder (empty at start)
- **SQL client window** → run the statements above

After each statement, wait ~10–30 seconds and refresh S3. Files appear under
`cdc-oracle/ADMIN/EMPLOYEES/`:

| Operation | File prefix | What's inside |
|---|---|---|
| UPDATE | `U` | Before-image and after-image of the row |
| INSERT | `I` | The new row + `cdc_ts` timestamp |
| DELETE | `D` | The deleted row |

---

### 7.4 Check task statistics (both options)

**DMS console → Tasks → `hr-cdc-task-<U>` → Table statistics:**

You should see for `ADMIN.EMPLOYEES`: `Full load rows` = 20, `Applied updates` ≥ 1,
`Applied inserts` ≥ 1, `Applied deletes` ≥ 1.

---

## Cleanup (REQUIRED before end of session)

Stop and delete everything you created: DMS resources cost real money per hour even when idle:

- DMS task (`hr-cdc-task-<U>`)
- DMS endpoints (`hr-source-oracle-<U>`, `hr-target-oracle-<U>` or `hr-target-s3-<U>`)
- DMS replication instance (`hr-cdc-rep-<U>`)
- RDS instance(s) (`hr-db-<U>`, and `hr-target-<U>` if you did Option A)
- IAM role (`dms-cdc-s3-role-oracle-<U>`) if you created one manually

## References

1. https://docs.aws.amazon.com/dms/latest/sbs/oracle-s3-data-lake.html
2. https://aws.amazon.com/blogs/database/achieve-a-high-performance-migration-to-amazon-rds-for-oracle-from-on-premises-oracle-with-aws-dms
3. https://docs.aws.amazon.com/dms/latest/sbs/chap-manageddatabases.oracle2rds.html

