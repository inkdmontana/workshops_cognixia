# DynamoDB Global Tables + CDC 

Table: `quicklabs-student-<NUMBER>-pipeline-tracker`, primary Region `us-west-2`, replica Region
`us-east-1`. Console only: no NoSQL Workbench.

---

## Task 1: Create the table

1. DynamoDB console (`us-west-2`) → **Create table**.
2. Table name: `quicklabs-student-<NUMBER>-pipeline-tracker`.
3. Partition key: `PK` (String). Sort key: `SK` (String).
4. Default settings otherwise (on-demand capacity). **Create table**.

## Task 2: Insert data

1. Table → **Explore table items** → **Create item** → **JSON view**.
2. Paste:
   ```json
   {
     "PK": {"S": "JOB#001"},
     "SK": {"S": "METADATA"},
     "JobType": {"S": "SensorIngestion"},
     "Status": {"S": "STARTED"}
   }
   ```
3. Create a second item, same `PK`, `SK` = `STATUS#<current timestamp>`, `Status` = `RUNNING`.

## Task 3: Add a Global Table replica

1. Table → **Global tables** tab → **Create replica** → Region `us-east-1`.
2. Wait for status `Active`.
3. Switch console Region to `us-east-1` → confirm both items are present in the replica.

## Task 4: Create the Kinesis stream (in the replica Region)

1. Console Region = `us-east-1`.
2. Kinesis console → **Create data stream** → name it `quicklabs-student-<NUMBER>-dynamodb-stream` → On-demand mode.

## Task 5: Enable Kinesis Data Streams for DynamoDB (on the replica)

1. Console Region = `us-east-1`.
2. Table `quicklabs-student-<NUMBER>-pipeline-tracker` → **Exports and streams** tab → **Kinesis data stream details** → **Enable** → select the stream from Task 4.
3. Wait ~30–60 seconds before testing: a freshly-enabled destination is slower on its first record than steady-state.

## Task 6: Validate end to end

1. Switch console Region back to `us-west-2`.
2. Write a **new** item to `quicklabs-student-<NUMBER>-pipeline-tracker` (same PK/SK shape as Task 2, new `SK` timestamp).
3. Switch Region to `us-east-1` → confirm the new item appears in the replica table.
4. Kinesis console (`us-east-1`) → your stream → **Data viewer** → pick any shard → **Get records**, iterator type `Trim horizon`.
5. Confirm a record matching your Task 6.2 item appears, with `eventName: INSERT` and your item's keys.

## Task 7: Lambda: Kinesis → S3

Consume the stream automatically and land each change event as a file in S3, instead of reading
records manually in the Data Viewer.

1. S3 console (`us-east-1`) → create bucket `quicklabs-student-<NUMBER>-raw-zone` (or reuse it if it
   already exists from an earlier lab).
2. Lambda console (`us-east-1`) → **Create function** → Python 3.x runtime
3. Additional Settings -> Custom execution role -> (SELECT) -> `QuicklabsDynamoDBLambdaDemo`
3. Paste this code:
   ```python
   import base64, json, boto3, time

   s3 = boto3.client("s3")
   BUCKET = "quicklabs-student-<NUMBER>-raw-zone"

   def lambda_handler(event, context):
       for record in event["Records"]:
           payload = base64.b64decode(record["kinesis"]["data"])
           data = json.loads(payload)
           key = f"dynamodb-cdc/{int(time.time()*1000)}-{record['eventID']}.json"
           s3.put_object(Bucket=BUCKET, Key=key, Body=json.dumps(data))
       return {"statusCode": 200}
   ```
5. **Deploy**.
6. **Add trigger** → Kinesis → select the stream from Task 4 - `quicklabs-student-<NUMBER>-dynamodb-stream` → batch size 1 → **Add**.

## Task 8: Validate the full pipeline

1. Repeat Task 6.2: write a **new** item to `quicklabs-student-<NUMBER>-pipeline-tracker` in `us-west-2`.
2. Wait ~30 seconds.
3. S3 console → `quicklabs-student-<NUMBER>-raw-zone` → `dynamodb-cdc/` → confirm a new JSON file appeared.
4. Open it: confirm it contains your item's `Keys` and `NewImage`.

**Done when:** one write in `us-west-2` produces a matching file in S3, with no manual step
between the DynamoDB write and the S3 object appearing.

---

## Common pitfalls

- Check the console Region selector (top-right) before every step: most "nothing happened" confusion is being in the wrong Region.
- If the Kinesis data viewer shows nothing right after enabling the destination, wait another minute before assuming it's broken.
- `PK`/`SK` are case-sensitive and must match exactly across all items you create.
- Lambda's Kinesis trigger delivers each record **at least once**: a duplicate S3 file for the
  same event is expected behavior, not a bug (this is why the S3 key includes a timestamp+eventID,
  not just the item's PK).
- If the Lambda IAM role is missing the S3 `PutObject` permission, the function fails silently
  from the console's point of view: check **Monitor → Logs** on the function for the actual error.
