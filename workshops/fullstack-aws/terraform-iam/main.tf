###############################################################################
# Full-Stack on AWS — per-cohort IAM bootstrap
#
# Reads students.csv, creates one IAM user per row with:
#   - console login (temporary password, must change on first login)
#   - membership in the cohort group (which holds the sandbox managed policy)
#
# The sandbox policy is one simple region-locked, full-access-to-5-services
# policy shared by every student in the cohort — no per-student resource-name
# or tag scoping in IAM. This module also pre-creates ONE shared Lambda
# execution role per cohort so students never need any IAM permissions of
# their own; they just pass that one role's ARN into their lab Terraform.
#
# Multiple cohorts coexist via Terraform workspaces — one workspace per
# cohort, each pointing at its own roster CSV:
#
#   terraform workspace new batch-a
#   terraform apply -var=roster_csv=students-batch-a.csv
#
#   terraform workspace new batch-b
#   terraform apply -var=roster_csv=students-batch-b.csv
#
# The CSV's `cohort` column (same value across all rows in one file) drives
# the group name, managed policy name, and per-user `cohort` tag.
###############################################################################

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      workshop   = "full-stack"
      autodelete = "true"
      date       = var.created_date
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  roster_raw = csvdecode(file(var.roster_csv))

  # username keyed, drop blank rows and inactive students
  students = {
    for s in local.roster_raw : s.username => s
    if try(s.username, "") != "" && lower(try(s.active, "true")) != "false"
  }

  # username is an email; S3/Lambda/DynamoDB names can't contain "@" or ".",
  # so derive a slug (local-part of the email) for resource-name patterns.
  student_slugs = {
    for u, _ in local.students : u => split("@", u)[0]
  }

  # One CSV = one cohort. The group + managed policy are named after the
  # cohort so multiple batches can coexist in AWS (each batch gets its own
  # Terraform workspace/state). Read from the first row; all rows in a file
  # are expected to carry the same value.
  cohort = try(local.roster_raw[0].cohort, "fullstack-aws")
}

# --- IAM user per student ----------------------------------------------------

resource "aws_iam_user" "student" {
  for_each = local.students

  name          = each.key
  force_destroy = true   # removes access keys and MFA devices before deleting the user
  tags = {
    full_name = try(each.value.full_name, "")
    slug      = local.student_slugs[each.key]
    cohort    = try(each.value.cohort, local.cohort)
  }
}

resource "aws_iam_user_login_profile" "student" {
  for_each = aws_iam_user.student

  user                    = each.value.name
  password_reset_required = true

  # TODO: encrypt with a PGP key per student, or write to a sealed secret store.
  # For now Terraform generates a one-time password in state — handle state file
  # accordingly (the parent README's `students-credentials.csv` is gitignored).
}

# --- Shared Lambda execution role (one per cohort, not one per student) -----
#
# Students get ZERO IAM permissions of their own — no CreateRole, no
# AttachRolePolicy, nothing. Every lab that deploys a Lambda (task-tracker,
# url-bookmark-saver) passes THIS pre-created role's ARN in instead of
# creating its own. Covers what both labs need: CloudWatch Logs (basic
# execution) + DynamoDB (url-bookmark-saver's table). Safe to leave unused by
# labs that don't need DynamoDB (task-tracker).

resource "aws_iam_role" "lambda_shared" {
  name = "${var.name_prefix}-${local.cohort}-lambda-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_shared_basic" {
  role       = aws_iam_role.lambda_shared.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_shared_dynamodb" {
  name = "${var.name_prefix}-${local.cohort}-lambda-dynamodb"
  role = aws_iam_role.lambda_shared.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "dynamodb:*"
      Resource = "*"
    }]
  })
}

# --- Sandbox policy + group --------------------------------------------------
#
# Single, simple policy: region-locked to us-east-1, full access to Lambda,
# EC2, S3, CloudWatch, CloudFront, and DynamoDB. No per-student resource-name
# scoping — that used to be enforced via aws:PrincipalTag/slug ARN matching,
# which was fragile and hard to debug. Namespacing is now a *tagging*
# convention instead (see root README): every resource gets
# `workshop`/`autodelete`/`date` tags, and the nightly cleanup script deletes
# anything that isn't tagged, rather than IAM blocking creation of anything
# mis-named. The one exception is `iam:PassRole`, narrowly scoped to just the
# shared Lambda role above — that's the only IAM permission students get.

resource "aws_iam_policy" "fullstack_sandbox" {
  name        = "${var.name_prefix}-${local.cohort}-sandbox"
  description = "Region-locked (us-east-1) full access to Lambda/EC2/S3/CloudWatch/CloudFront/DynamoDB for ${local.cohort}, plus PassRole on the shared Lambda role only."

  policy = replace(
    file("${path.module}/../student-iam-policy.json"),
    "{ACCOUNT_ID}", data.aws_caller_identity.current.account_id
  )
}

resource "aws_iam_group" "fullstack_student" {
  name = "${var.name_prefix}-${local.cohort}-students"
}

resource "aws_iam_group_policy_attachment" "fullstack_sandbox" {
  group      = aws_iam_group.fullstack_student.name
  policy_arn = aws_iam_policy.fullstack_sandbox.arn
}

resource "aws_iam_user_group_membership" "student" {
  for_each = aws_iam_user.student

  user   = each.value.name
  groups = [aws_iam_group.fullstack_student.name]
}

# --- Credentials CSV (sensitive) --------------------------------------------
#
# Writes a one-row-per-student CSV that the admin uses to send welcome emails.
# Path is at the repo root and gitignored.

resource "local_sensitive_file" "credentials" {
  filename        = "${path.module}/../../../students-credentials-${local.cohort}.csv"
  file_permission = "0600"

  content = join("\n", concat(
    ["username,full_name,console_url,console_password,region,lambda_role_arn"],
    [
      for u, s in local.students :
      join(",", [
        u,
        try(s.full_name, ""),
        "https://${data.aws_caller_identity.current.account_id}.signin.aws.amazon.com/console",
        aws_iam_user_login_profile.student[u].password,
        var.region,
        aws_iam_role.lambda_shared.arn,
      ])
    ]
  ))
}
