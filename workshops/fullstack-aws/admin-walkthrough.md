# Admin walkthrough: Full-Stack on AWS

End-to-end the instructor runs once per cohort, before students arrive.

See [`README.md`](README.md) for the design overview (slug derivation, group/policy model, multi-cohort workspaces). This doc is the runbook.

## Prereqs

- AWS CLI configured with admin creds for the cohort account (`aws sts get-caller-identity` works)
- Terraform ≥ 1.5 (`brew install terraform`)
- `gh` CLI authenticated as an org owner of `{ORG}` (`gh auth status`)
- The cohort's GitHub team exists (`gh api /orgs/{ORG}/teams/{TEAM_SLUG}` returns 200)
- A Copilot Business subscription on the org with seats available

## Step 0: Roster

One CSV per cohort. Columns: `username,full_name,cohort`. All rows in one file share the same cohort value.

```bash
cd workshops/fullstack-aws/terraform-iam
cp students.csv.example students.csv
$EDITOR students.csv
```

Example row:

```csv
username,full_name,cohort
alice-johnson@quicklabs.internal,Alice Johnson,fullstack-aws-batch-a
```

For a second cohort, keep a parallel file (`students-batch-b.csv`) and pass it via `-var=roster_csv=...` on apply.

## Step 1: GitHub: team + Copilot

Independent of the AWS side. Maintain GitHub handles in your own roster (the AWS CSV no longer carries them).

```bash
cd ../github

# 1a. Invite all students to the cohort team.
ORG=becloudready TEAM_SLUG=fullstack-cohort-01 ./add-team-members.sh github-roster.csv

# 1b. Assign Copilot seats.
ORG=becloudready ./invite-copilot.sh github-roster.csv
```

Both scripts are idempotent: re-run them to add late joiners.

## Step 2: AWS: IAM users + sandbox policy + group

Per-cohort Terraform workspace. One workspace = one cohort = one isolated state file.

```bash
cd ../terraform-iam
terraform init                               # one-time
terraform workspace new batch-a              # one-time per cohort
terraform apply                              # uses students.csv
```

For batch B later:

```bash
terraform workspace new batch-b
terraform apply -var=roster_csv=students-batch-b.csv
```

What got created per cohort (`<cohort>` = the value in the CSV's `cohort` column):

- Managed policy `quicklabs-<cohort>-sandbox`: one simple policy: region-locked to `us-east-1`, full access to Lambda/EC2/S3/CloudWatch/CloudFront. No per-user resource-name scoping anymore (that used to be `${aws:PrincipalTag/slug}` ARN matching, which was fragile and hard to debug). Namespacing is now just a tagging convention (see README) enforced by the nightly cleanup script, not IAM.
- IAM group `quicklabs-<cohort>-students` with the managed policy attached
- One IAM user per CSV row, named with the email-form `username`, tagged with `slug` + `full_name` + `cohort`
- Per-user login profile (20-char password, reset required on first login)
- Per-user group membership

Outputs:

- `terraform output -json students`: sensitive map (scriptable)
- `students-credentials-<cohort>.csv` at the repo root (chmod 0600, gitignored): `username, full_name, console_url, console_password, region`. Filename is cohort-aware, so batch A and batch B write to separate files automatically.

## Step 3: Distribute credentials

The output file path is exposed as a Terraform output so you don't have to guess the cohort suffix:

```bash
cd workshops/fullstack-aws/terraform-iam
CREDS_FILE=$(terraform output -raw credentials_csv_path)

while IFS=, read -r username full_name console_url console_password region lambda_role_arn; do
  [[ "$username" == "username" ]] && continue
  cat <<EOF
to: $username
  GitHub:     accept the invite to {ORG}/{TEAM_SLUG} and the Copilot seat (check your email)
  AWS console: $console_url
  username:   $username
  password:   $console_password   (must change on first login)
  region:     $region (anything else is denied)
  Your slug:  ${username%@*}
              (use this as student_name= when running bootcamp Terraform)
  Lambda role: $lambda_role_arn
              (use this as lambda_role_arn= in the task-tracker / url-bookmark-saver labs: you don't create your own IAM role)

EOF
done < "$CREDS_FILE"
```

## Step 4: Smoke test (one student, incognito)

| Test | Expected |
|---|---|
| GitHub: sign in, see {ORG}/{TEAM_SLUG} repos | ✅ |
| GitHub: open VS Code, Copilot suggests inline | ✅ |
| AWS: sign in to console in `us-east-1` | ✅ |
| AWS: switch to `us-west-2`, open any service | mostly denied |
| AWS: create an S3 bucket (any name) | ✅ |
| AWS: create/invoke a Lambda function | ✅ |
| AWS: launch any EC2 instance type | ✅ |
| AWS: try to create another IAM user | ❌ denied (only IAM permission granted is `iam:PassRole` on the shared Lambda role) |
| Terraform: `cd projects/01-task-tracker/terraform && terraform apply -var=student_name=<slug> -var=created_date=<dd-mmm-yyyy> -var=lambda_role_arn=<arn from credentials CSV> ...` | ✅ |

**Resolved:** `task-tracker` and `url-bookmark-saver` no longer create their own Lambda execution role. Both reference the one shared role this module pre-creates per cohort (`aws_iam_role.lambda_shared`: basic execution + full DynamoDB access). Students get zero IAM permissions of their own beyond passing that one role to Lambda. The role's ARN is in the credentials CSV (`lambda_role_arn` column) and in `terraform output lambda_role_arn`.

Each failed expectation → one edit to `student-iam-policy.json` → `terraform apply` to re-render the managed policy.

## Cohort teardown

Two-phase: tear down the student-built lab resources first, then the IAM scaffolding.

```bash
# 1. Lab resources students built during the bootcamp (Lambda, S3, DynamoDB, EC2, log groups, IAM roles)
#    NOTE: cleanup-student-resources.py still matches by the student-<slug>-* name prefix
#    (with tag-based matching as an add-on). It has NOT yet been updated to the
#    new "delete anything missing workshop/autodelete/date tags" model described
#    in the README. Until that follow-up lands, students who skip the naming
#    convention won't be caught by this script even though the README says tags
#    are what's enforced. Treat this as a known gap, not yet fixed.
cd ~/workspace/fullstack-bootcamp
while IFS=, read -r username _; do
  [[ "$username" == "username" ]] && continue
  slug="${username%@*}"
  python tools/cleanup-student-resources.py --student "$slug" --region us-east-1
done < ~/workspace/quick-labs/workshops/fullstack-aws/terraform-iam/students.csv

# 2. IAM scaffolding for this cohort (users, group, managed policy, memberships)
cd ~/workspace/quick-labs/workshops/fullstack-aws/terraform-iam
terraform workspace select batch-a
terraform destroy

# 3. GitHub: remove from team + revoke Copilot seats (skips active=true rows).
cd ../github
ORG=becloudready TEAM_SLUG=fullstack-cohort-01 ./remove-team-members.sh github-roster.csv
ORG=becloudready ./revoke-copilot.sh github-roster.csv
```

Order matters: destroy lab resources first while students still have permissions to inspect what's there if needed, then yank the IAM scaffolding.
