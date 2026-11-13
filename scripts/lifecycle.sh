#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

stack_output() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text
}

require_stable_stack() {
  local status
  status=$(aws cloudformation describe-stacks --stack-name "$1" \
    --query 'Stacks[0].StackStatus' --output text)
  case "$status" in
    CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE|IMPORT_COMPLETE) ;;
    *) fail "Stack $1 is not ready. Check its Events in CloudFormation." ;;
  esac
}

require_absent_stack() {
  local error
  if error=$(aws cloudformation describe-stacks --stack-name "$1" \
    --query 'Stacks[0].StackStatus' --output text 2>&1); then
    fail "Stack $1 still exists. Check its status in CloudFormation."
  fi
  if [[ "$error" != *"(ValidationError)"* || "$error" != *"Stack with id $1 does not exist"* ]]; then
    fail "Could not confirm that stack $1 is absent."
  fi
}

require_clear_queues() {
  local key queue attributes
  require_stable_stack tindy-integrations
  for key in GuardDutyQueueUrl GuardDutyDeadLetterQueueUrl; do
    queue=$(stack_output tindy-integrations "$key")
    attributes=$(aws sqs get-queue-attributes --queue-url "$queue" --attribute-names \
      ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
      ApproximateNumberOfMessagesDelayed --query Attributes --output json)
    jq -e '
      .ApproximateNumberOfMessages == "0" and
      .ApproximateNumberOfMessagesNotVisible == "0" and
      .ApproximateNumberOfMessagesDelayed == "0"
    ' <<< "$attributes" >/dev/null || fail "Queue $key reports pending or unverified work."
  done
}

require_image() {
  local digest
  [[ "$IMAGE_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || fail "Enter the SHA-256 digest of the API image."
  digest=$(aws ecr describe-images --repository-name tindy-api \
    --image-ids "imageDigest=$IMAGE_DIGEST" --query 'imageDetails[0].imageDigest' --output text)
  [[ "$digest" == "$IMAGE_DIGEST" ]] || fail "The requested digest was not verified in ECR."
}

require_database() {
  require_stable_stack tindy-database
  local identifier
  identifier=$(stack_output tindy-database DBInstanceIdentifier)
  [[ "$identifier" == tindy-database-postgres ]] || fail "Unexpected DB instance identifier."
  database=$(aws rds describe-db-instances --db-instance-identifier "$identifier" \
    --query 'DBInstances[0].{Status:DBInstanceStatus,ResourceId:DbiResourceId,Protected:DeletionProtection,Encrypted:StorageEncrypted,Public:PubliclyAccessible}' --output json)
  jq -e '.Status == "available" and .Encrypted and .Public == false and (.ResourceId | length > 0)' \
    <<< "$database" >/dev/null || fail "The Tindy DB must be available, encrypted, and private."
}

require_snapshot() {
  [[ "$SNAPSHOT_ID" =~ ^tindy-[a-z0-9]+(-[a-z0-9]+)*$ && ${#SNAPSHOT_ID} -le 255 ]] ||
    fail "Enter a Tindy manual snapshot ID beginning with tindy-."
  snapshot=$(aws rds describe-db-snapshots --db-snapshot-identifier "$SNAPSHOT_ID" \
    --snapshot-type manual --query 'DBSnapshots[0].{Id:DBSnapshotIdentifier,Arn:DBSnapshotArn,Status:Status,Encrypted:Encrypted,Engine:Engine,Version:EngineVersion,Instance:DBInstanceIdentifier,ResourceId:DbiResourceId,Created:SnapshotCreateTime}' --output json)
  jq -e --arg id "$SNAPSHOT_ID" '
    .Id == $id and .Status == "available" and .Encrypted and .Engine == "postgres" and
    (.Version | startswith("17.")) and .Instance == "tindy-database-postgres" and
    (.Created | length > 0) and (.Arn | length > 0)
  ' <<< "$snapshot" >/dev/null || fail "The snapshot must be available, encrypted PostgreSQL 17 from Tindy."
}

require_maintenance_edge() {
  require_stable_stack tindy-edge
  local mode distribution
  mode=$(stack_output tindy-edge EdgeMode)
  [[ "$mode" == maintenance ]] || fail "Switch tindy-edge to maintenance and wait for deployment."
  distribution=$(stack_output tindy-edge DistributionId)
  edge=$(aws cloudfront get-distribution --id "$distribution" \
    --query 'Distribution.{Id:Id,Status:Status,Domain:DomainName,Origins:DistributionConfig.Origins.Items[].VpcOriginConfig.VpcOriginId}' --output json)
  jq -e --arg id "$distribution" '.Id == $id and .Status == "Deployed" and ((.Origins // []) | length == 0)' \
    <<< "$edge" >/dev/null || fail "CloudFront must be deployed with no VPC Origin references."
  local domain response
  domain=$(jq -er '.Domain | select(test("^[a-z0-9]+[.]cloudfront[.]net$"))' <<< "$edge")
  response=$(curl --silent --show-error --max-time 15 --output "$RUNNER_TEMP/tindy-maintenance.json" \
    --write-out '%{http_code}' "https://$domain/api/health/ready")
  [[ "$response" == 503 ]] &&
    jq -e '.status == "maintenance"' "$RUNNER_TEMP/tindy-maintenance.json" >/dev/null ||
    fail "The public API did not return the expected maintenance response."
}

report_snapshot() {
  jq -r '"\n- Snapshot ID: `\(.Id)`\n- Snapshot ARN: `\(.Arn)`\n- Snapshot created: `\(.Created)`\n- Snapshot status: `\(.Status)`\n- Encrypted: `\(.Encrypted)`"' <<< "$snapshot"
}

case "$OPERATION" in
  backup)
    require_database
    require_clear_queues
    require_image
    [[ "$MIGRATION_ID" =~ ^[0-9]{14}_[a-zA-Z0-9_]+$ ]] || fail "Enter the latest verified EF migration ID."
    SNAPSHOT_ID="tindy-backup-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
    aws rds create-db-snapshot --db-instance-identifier tindy-database-postgres \
      --db-snapshot-identifier "$SNAPSHOT_ID" --query 'DBSnapshot.DBSnapshotIdentifier' --output text
    aws rds wait db-snapshot-available --db-snapshot-identifier "$SNAPSHOT_ID"
    require_snapshot
    database_id=$(jq -er '.ResourceId' <<< "$database")
    jq -e --arg id "$database_id" '.ResourceId == $id' <<< "$snapshot" >/dev/null ||
      fail "The snapshot belongs to a different physical DB instance."
    {
      echo '## Tindy backup'
      report_snapshot
      printf -- '- API image digest: `%s`\n- Operator-verified migration ID: `%s`\n' "$IMAGE_DIGEST" "$MIGRATION_ID"
    } >> "$GITHUB_STEP_SUMMARY"
    ;;
  teardown)
    require_database
    require_clear_queues
    require_snapshot
    [[ "$SNAPSHOT_ID" =~ ^tindy-backup-[0-9]+-[0-9]+$ ]] ||
      fail "Use the snapshot ID produced by the Backup workflow for this maintenance window."
    database_id=$(jq -er '.ResourceId' <<< "$database")
    jq -e --arg id "$database_id" '.ResourceId == $id' <<< "$snapshot" >/dev/null ||
      fail "The snapshot belongs to a different physical DB instance."
    require_maintenance_edge
    {
      echo '## Tindy teardown preflight'
      report_snapshot
      printf '\nRDS deletion protection: `%s`\n' "$(jq -r '.Protected' <<< "$database")"
      echo 'Recheck the maintenance window and follow the manual stack deletion order in the runbook.'
    } >> "$GITHUB_STEP_SUMMARY"
    ;;
  redeploy)
    case "$PROVISION_MODE" in
      Restore) require_snapshot ;;
      Fresh) [[ -z "$SNAPSHOT_ID" ]] || fail "Leave snapshot ID blank for Fresh." ;;
      *) fail "Choose Restore or Fresh." ;;
    esac
    require_image
    require_stable_stack tindy-foundation
    require_stable_stack tindy-network
    require_maintenance_edge
    for stack in tindy-database tindy-runtime tindy-integrations; do
      require_absent_stack "$stack"
    done
    {
      echo '## Tindy redeploy preflight'
      printf '\n- Database mode: `%s`\n- API image digest: `%s`\n' "$PROVISION_MODE" "$IMAGE_DIGEST"
      jq -r '"- CloudFront distribution: `\(.Id)`\n- CloudFront hostname: `\(.Domain)`"' <<< "$edge"
      if [[ "$PROVISION_MODE" == Restore ]]; then report_snapshot; fi
      printf '\nFollow the selected path in the runbook and review CloudFormation Change Sets in the AWS Console.\n'
    } >> "$GITHUB_STEP_SUMMARY"
    ;;
  *) fail "Unsupported lifecycle operation." ;;
esac
