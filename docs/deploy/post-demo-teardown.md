# Backup và teardown sau buổi trình diễn

Dùng runbook này khi team đã kết thúc đợt sử dụng Tindy và muốn giảm chi phí vận hành. Thao tác AWS ở **N. Virginia (`us-east-1`)** bằng danh tính vận hành đã được cấp quyền. Nếu team còn test trên link hiện tại, hẹn giờ bảo trì trước khi bắt đầu.

| Xóa theo thứ tự | Giữ để dựng lại |
| --- | --- |
| `tindy-runtime` → `tindy-database` → `tindy-integrations` | `tindy-foundation`, `tindy-network`, `tindy-edge`, snapshot phục hồi, dữ liệu S3, image ECR, secrets và Data Protection key ring |

## 1. Chốt cửa sổ bảo trì và dừng ghi dữ liệu

1. Chỉ định người điều phối. Báo team ngừng sử dụng app, ngừng upload, gọi AI và chạy deploy từ GitHub Actions hoặc AWS Console trong suốt cửa sổ bảo trì.
2. Để worker tiếp tục xử lý các việc đã nhận. Kiểm tra verdict GuardDuty, hai queue SQS và trạng thái upload còn `scanning` hoặc đang chờ xử lý. Đối chiếu các tác vụ chat và notification còn dang dở theo dữ liệu ứng dụng. Khi có PDF chờ quét, giữ nguyên cách ly và xử lý hoặc ghi nhận rõ trước khi tiếp tục.
3. Trong **SQS → Queues**, kiểm tra cả `tindy-integrations-pdf-scan` và `tindy-integrations-pdf-scan-dlq`. Kiểm tra đủ ba chỉ số `visible`, `in flight` và `delayed` bằng PowerShell. Các số liệu là xấp xỉ. Đọc lại sau khi hệ thống yên và đối chiếu với trạng thái ứng dụng. Nếu còn message hoặc còn ghi dữ liệu chưa kiểm soát được, dừng và xử lý trước khi snapshot. Tránh dùng **Purge** để đưa số đếm về 0.

```powershell
$awsOptions = @('--profile', 'tindy-admin', '--region', 'us-east-1', '--no-cli-pager')
foreach ($name in @('tindy-integrations-pdf-scan', 'tindy-integrations-pdf-scan-dlq')) {
    $queueUrl = aws sqs get-queue-url --queue-name $name --query QueueUrl --output text @awsOptions
    if ($LASTEXITCODE -ne 0 -or -not $queueUrl -or $queueUrl -eq 'None') {
        throw "Không tìm được queue $name."
    }
    $name
    aws sqs get-queue-attributes --queue-url $queueUrl --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed --query Attributes --output table @awsOptions
    if ($LASTEXITCODE -ne 0) { throw "Không đọc được queue $name." }
}
```

## 2. Tạo snapshot bằng Backup Tindy

1. Vào **ECS → Clusters → tindy-runtime → Services → tindy-api → Tasks**. Mở task **Running**, kiểm tra revision và image của container `api`. Với lần deploy pin theo digest, lấy phần `sha256:…` từ **Image URI**. Khi vừa rollout, đợi service ổn định và xác nhận các task phục vụ dùng cùng bản. Tham số `ApiImage` trong CloudFormation có thể còn là bản cũ sau backend CD.
2. Lấy migration EF mới nhất từ dòng `Latest migration` của one-off task thành công trong **CloudWatch Logs → /ecs/tindy-runtime → migration/migration/…**, hoặc từ kết quả đối chiếu chỉ đọc bảng `__EFMigrationsHistory` trên đúng RDS. Khi log thuộc instance cũ hoặc đã có thay đổi schema sau đó, ưu tiên đọc lịch sử trên DB hiện hành. Copy ID đầy đủ, bỏ dấu chấm cuối câu trong log. Workflow ghi lại ID do người vận hành cung cấp.
3. Trong repo **tindy-infrastructure → Actions → Backup Tindy → Run workflow**, chọn `main`. Điền `confirm = BACKUP TINDY`, `image_digest = sha256:…` và `migration_id` đã đối chiếu. Nếu workflow báo thiếu role, kiểm tra `TINDY_LIFECYCLE_ROLE_ARN` theo [trang tổng quan](../lifecycle.md).
4. Chờ **Success**, mở Summary và ghi **Snapshot ID/ARN**, thời điểm tạo, `available`, `Encrypted: true`, image digest, migration ID và link run. Vào **RDS → Snapshots → Manual** và đối chiếu đúng snapshot. Với từng mốc, ghi thêm commit BE/FE nếu biết, CloudFront distribution ID/domain, các tham số stack, object key/version S3 của dữ liệu cần giữ và bản ghi kiểm chứng sẽ dùng sau restore. Giữ manifest tại nơi team kiểm soát quyền truy cập. Với secrets và key ring chỉ ghi tên, ARN hoặc path.
5. Đối chiếu image còn trong ECR, media bắt buộc còn trên S3 và thông tin đăng nhập DB tương ứng với snapshot còn dùng được khi restore. Giữ **Golden Snapshot và hai snapshot gần nhất đã xác minh**. Nếu có ghi dữ liệu mới sau mốc snapshot, chốt lại quiescence và tạo snapshot mới trước khi xóa.

## 3. Đưa CloudFront về maintenance và chạy preflight

1. Vào **CloudFormation → tindy-edge → Stack actions → Create change set**. Dùng **Use existing template**, đặt tên ví dụ `tindy-edge-maintenance`, chọn `EdgeMode = maintenance`, giữ `FrontendBucketName`. Khi có thể nhập giá trị rỗng tường minh, xóa giá trị `AlbDnsName` và `VpcOriginId` để tránh nhầm khi mở lại. Template dùng `EdgeMode` để gỡ origin backend khỏi distribution.
2. Tạo và xem **Resource changes**. Khi chuyển từ `live`, kỳ vọng `EdgeDistribution → Modify → Replacement = False`. Execute, chờ stack `UPDATE_COMPLETE` và CloudFront **Deployed**. Trong **Origins** và **Behaviors**, đối chiếu backend origin đã được gỡ, còn origin S3 frontend. Kiểm tra distribution ID/domain giống bản đã ghi, frontend vẫn mở theo cấu hình maintenance và API trả HTTP `503` với JSON `{"status":"maintenance"}`.

```powershell
$edgeHost = Read-Host 'DistributionDomainName từ Outputs của tindy-edge'
curl.exe -i "https://$edgeHost/api/health/ready"
```

3. Chạy **Actions → Teardown Tindy → Run workflow** trên `main`. Điền `confirm = TEARDOWN TINDY` và `snapshot_id` từ Backup của cửa sổ này. Đọc Summary và xác nhận snapshot `available`, mã hóa và thuộc đúng DB vật lý của đợt teardown. Workflow này chạy kiểm tra. Các bước xóa thực hiện trong Console.

## 4. Xóa tindy-runtime

1. Lưu **Parameters** của stack để phục vụ dựng lại. Nếu `CloudFrontServiceSecurityGroupId` đang trỏ đến service SG, chuyển rule ALB về CloudFront prefix list bằng Change Set. Dùng template hiện tại, đặt tên ví dụ `tindy-runtime-prepare-delete`, để trống tường minh `CloudFrontServiceSecurityGroupId`, điền `CloudFrontOriginPrefixListId` theo managed prefix list IPv4 `com.amazonaws.global.cloudfront.origin-facing` ở Region hiện tại, và giữ các giá trị khác.
2. Nếu Console trả về **no changes** và ALB vẫn tham chiếu service SG, tạo Change Set bằng CLI với `ParameterValue = ''` trong JSON. Lệnh dưới đây chạy trong cùng PowerShell với `$awsOptions` ở trên.

```powershell
$prefixId = aws ec2 describe-managed-prefix-lists --filters 'Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing' --query 'PrefixLists[0].PrefixListId' --output text @awsOptions
if ($LASTEXITCODE -ne 0 -or $prefixId -notmatch '^pl-[0-9a-f]+$') {
    throw 'Không xác minh được CloudFront prefix list.'
}
$keysJson = aws cloudformation describe-stacks --stack-name tindy-runtime --query 'Stacks[0].Parameters[].ParameterKey' --output json @awsOptions
if ($LASTEXITCODE -ne 0) { throw 'Không đọc được tham số của tindy-runtime.' }
$keys = $keysJson | ConvertFrom-Json
if ('CloudFrontServiceSecurityGroupId' -notin $keys -or 'CloudFrontOriginPrefixListId' -notin $keys) {
    throw 'Stack thiếu tham số CloudFront cần cập nhật.'
}
$parameters = foreach ($key in $keys) {
    switch ($key) {
        'CloudFrontServiceSecurityGroupId' { @{ ParameterKey = $key; ParameterValue = '' } }
        'CloudFrontOriginPrefixListId' { @{ ParameterKey = $key; ParameterValue = $prefixId } }
        default { @{ ParameterKey = $key; UsePreviousValue = $true } }
    }
}
$parameterFile = New-TemporaryFile
try {
    ConvertTo-Json -InputObject @($parameters) -Depth 4 |
        Set-Content -LiteralPath $parameterFile.FullName -Encoding utf8
    $changeSetName = "tindy-runtime-prepare-delete-$(Get-Date -Format yyyyMMddHHmmss)"
    aws cloudformation create-change-set --stack-name tindy-runtime --change-set-name $changeSetName --change-set-type UPDATE --use-previous-template --capabilities CAPABILITY_NAMED_IAM --parameters "file://$($parameterFile.FullName)" @awsOptions
    if ($LASTEXITCODE -ne 0) { throw 'Không tạo được Change Set.' }
}
finally {
    Remove-Item -LiteralPath $parameterFile.FullName
}
```

3. Trong **Change sets**, kiểm tra chỉ có `AlbIngressFromCloudFront → Modify → Replacement = True`. Execute, chờ `UPDATE_COMPLETE`, rồi vào **EC2 → Security Groups → tindy-alb-sg → Inbound rules**. Rule TCP 80 phải lấy nguồn từ prefix list. Nếu rule đã dùng đúng prefix list từ trước, chuyển thẳng sang bước xóa.
4. Chọn **CloudFormation → tindy-runtime → Delete stack**, xác nhận đúng tên và để **Express mode** bỏ chọn. Nếu stack đang bật termination protection, tắt cho đúng stack này trong cửa sổ đã duyệt. Chờ `DELETE_COMPLETE` rồi kiểm ECS service, ALB, target group và CloudFront VPC Origin cũ đã được dọn. Nếu `DELETE_FAILED`, đọc **Events** để xác định dependency còn vướng trước khi thử lại.

## 5. Xóa tindy-database

1. Kiểm tra snapshot đã chọn vẫn **Available** và mã hóa. Lưu **Parameters** của DB stack. Tạo Change Set dùng template hiện tại, đặt `EnableDeletionProtection = false`, giữ `DBProvisionMode`, `DBSnapshotIdentifier` và tham số mạng theo stack đang chạy. Ví dụ khi stack hiện là `Restore`, giữ nguyên snapshot parameter mà stack đang dùng.
2. Chỉ thực thi nếu thấy `PostgresInstance → Modify → Replacement = False` và phần chi tiết khớp việc tắt bảo vệ. Chờ `UPDATE_COMPLETE`, vào **RDS → Databases → tindy-database-postgres → Configuration** và xác nhận **Deletion protection = Disabled**.
3. Quay lại **CloudFormation → tindy-database → Delete stack**, xác nhận tên và để **Express mode** bỏ chọn. Template dùng `DeletionPolicy: Snapshot`, vì vậy ghi nhận snapshot phát sinh lúc xóa riêng với snapshot được chọn ở bước 2. Kiểm tra stack `DELETE_COMPLETE` và DB instance không còn trong danh sách RDS.

## 6. Xóa tindy-integrations và chốt biên bản

1. Đọc lại cả ba số đếm của cả hai queue trong mục 1. Nếu có tồn đọng, giữ stack và xử lý theo verdict/trạng thái nghiệp vụ. Khi các mục đã đối chiếu xong, chọn **CloudFormation → tindy-integrations → Delete stack**, xác nhận đúng tên và chờ `DELETE_COMPLETE`.
2. Kiểm tra queue chính/DLQ, protection plan, EventBridge rule và các alarm/SNS thuộc stack này đã được dọn. Xác nhận CloudFront vẫn trả maintenance, ba stack giữ lại còn hoạt động, snapshot có thể chọn để restore, và S3/ECR/secrets/SSM vẫn có các mục đã ghi trong manifest.
3. Rà **Billing → Cost Explorer / Budgets** cùng inventory RDS, ECS, ALB, IP và CloudWatch Logs. Snapshot, lưu trữ S3/ECR và những tài nguyên giữ lại có thể tiếp tục phát sinh phí. Ghi lại mục bất thường, thời điểm kiểm tra và người chịu trách nhiệm.
4. Giao snapshot ID, image digest và manifest cho lượt [redeploy](redeploy.md). Decommission là lượt riêng cần xác nhận, với mốc rà soát sau 30 ngày kể từ kết quả chấm cuối theo kế hoạch.

[Hướng dẫn CloudFormation Change Sets](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets.html)
