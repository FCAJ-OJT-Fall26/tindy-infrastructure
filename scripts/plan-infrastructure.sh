#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  foundation|network|edge|database|runtime|integrations) ;;
  *) echo "::error::Select one of the Tindy stacks."; exit 1 ;;
esac

stack="tindy-$1"
template="cloudformation/$1.yaml"
change_set="github-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"

if (( $(wc -c < "$template") > 51200 )); then
  echo "::error::The template exceeds the CloudFormation inline template limit."
  exit 1
fi

template_keys=$(python - "$template" <<'PY'
import json
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    template = yaml.load(stream, Loader=yaml.BaseLoader)
print(json.dumps(list(template.get("Parameters", {}))))
PY
)

stack_state=$(aws cloudformation describe-stacks --stack-name "$stack" \
  --query 'Stacks[0].{Status:StackStatus,ParameterKeys:Parameters[].ParameterKey}' --output json)
case "$(jq -er '.Status' <<< "$stack_state")" in
  CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE) ;;
  *) echo "::error::The stack is not ready for an update. Check its status in CloudFormation."; exit 1 ;;
esac
existing_keys=$(jq -c '.ParameterKeys // []' <<< "$stack_state")
jq --argjson existing "$existing_keys" '
  [ .[] | select(. as $key | $existing | index($key))
        | {ParameterKey: ., UsePreviousValue: true} ]
' <<< "$template_keys" > "$RUNNER_TEMP/previous-parameters.json"

printf '### CloudFormation preview\n\n- Stack: `%s`\n- Commit: `%s`\n- Change Set: `%s`\n' \
  "$stack" "$GITHUB_SHA" "$change_set" >> "$GITHUB_STEP_SUMMARY"

change_set_id=$(aws cloudformation create-change-set \
  --stack-name "$stack" --change-set-name "$change_set" --change-set-type UPDATE \
  --description "Preview from GitHub Actions commit $GITHUB_SHA" \
  --template-body "file://$template" \
  --parameters "file://$RUNNER_TEMP/previous-parameters.json" \
  --capabilities CAPABILITY_NAMED_IAM --query Id --output text)
printf -- '- Change Set ARN: `%s`\n' "$change_set_id" >> "$GITHUB_STEP_SUMMARY"

# The waiter also exits nonzero when CloudFormation reports a no-op.
aws cloudformation wait change-set-create-complete --stack-name "$stack" \
  --change-set-name "$change_set_id" || true

# Read only status and resource names. Parameter values and property details
# belong in the AWS Console, especially for a public GitHub repository.
preview=$(aws cloudformation describe-change-set --stack-name "$stack" \
  --change-set-name "$change_set_id" --output json \
  --query '{Status:Status,Execution:ExecutionStatus,Reason:StatusReason,Changes:Changes[].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}}')

status=$(jq -er '.Status' <<< "$preview")
reason=$(jq -r '.Reason // ""' <<< "$preview")
printf -- '- AWS status: `%s`\n' "$status" >> "$GITHUB_STEP_SUMMARY"

if [[ "$status" == FAILED ]] &&
   [[ "$reason" == *"didn't contain changes"* || "$reason" == *"No updates are to be performed"* ]]; then
  echo 'CloudFormation found no changes.' >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

if [[ "$status" != CREATE_COMPLETE || $(jq -r '.Execution' <<< "$preview") != AVAILABLE ]]; then
  echo "::error::CloudFormation did not produce an available Change Set. Open it in the AWS Console for the status reason."
  exit 1
fi

{
  printf '\n| Action | Logical resource | Type | Replacement |\n|---|---|---|---|\n'
  jq -r '.Changes[]? | "| \(.Action) | \(.LogicalId) | \(.Type) | \(.Replacement // "-") |"' <<< "$preview"
  if jq -e 'any(.Changes[]?; .Action == "Remove" or .Replacement == "True" or .Replacement == "Conditional")' <<< "$preview" >/dev/null; then
    printf '\n**Review required:** resources may be removed or replaced.\n'
  fi
  printf '\nReview and execute the Change Set in the AWS Console.\n'
} >> "$GITHUB_STEP_SUMMARY"
