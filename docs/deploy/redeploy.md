# Dựng lại Tindy sau teardown

Dùng **Restore** để lấy lại dữ liệu của một snapshot, như lượt STEP 15 đã thực hiện. Chọn **Fresh** khi chủ đích bắt đầu với DB mới và nạp dữ liệu mẫu. Thực hiện ở **N. Virginia (`us-east-1`)**, dùng template đã review trên `main` của repo `tindy-infrastructure`. Giữ Edge ở `maintenance` đến khi ECS, DB và tích hợp quét PDF sẵn sàng.

## 1. Chạy Redeploy Tindy preflight

1. Lấy manifest từ [lượt backup](post-demo-teardown.md). Kiểm tra ba stack `tindy-foundation`, `tindy-network`, `tindy-edge`, hostname CloudFront ban đầu, image trong ECR, S3 media/version, Secrets Manager, SSM Data Protection và tình trạng budget/credits. Khi khôi phục, chọn cặp snapshot và image đã đối chiếu cùng migration ID.
2. Vào **tindy-infrastructure → Actions → Redeploy Tindy → Run workflow**. Chọn `main`, nhập các trường sau.

   | Trường | Restore | Fresh |
   | --- | --- | --- |
   | `confirm` | `REDEPLOY TINDY` | `REDEPLOY TINDY` |
   | `provision_mode` | `Restore` | `Fresh` |
   | `snapshot_id` | Snapshot ID thủ công đã chọn | Để trống |
   | `image_digest` | `sha256:…` đã ghi trong backup | `sha256:…` của release đã duyệt |

3. Chờ **Success**. Kiểm tra Summary có đúng mode, digest, distribution ID/domain và snapshot nếu chọn Restore. Workflow chỉ kiểm tra điều kiện đầu vào. Dựng từng stack trong Console.

## 2. Tạo lại database và kiểm tra secrets

1. Vào **CloudFormation → Create stack → With new resources (standard)**. Upload [database.yaml](../../cloudformation/database.yaml), đặt tên `tindy-database`. Chọn tham số.

   | Parameter | Giá trị |
   | --- | --- |
   | `DBProvisionMode` | `Restore` hoặc `Fresh` theo preflight |
   | `DBSnapshotIdentifier` | Snapshot ID đã xác minh với Restore, để trống với Fresh |
   | `EnableDeletionProtection` | `true` |
   | `DatabaseSecurityGroupId` | Output cùng tên từ `tindy-network` |
   | `PrivateDbSubnetIds` | Hai DB subnet từ `tindy-network` |

2. Dùng các tag vận hành `Project=Tindy`, `Environment=tindy`, `Owner=TindyTeam` nếu đây vẫn là bộ tag của stack. Tạo Change Set, ví dụ `tindy-database-restore`. Kiểm tra **Input** và ba mục `Add` gồm `DatabaseSubnetGroup`, `PostgresInstance` và `PostgresParameterGroup`. Execute, chờ `CREATE_COMPLETE` và RDS **Available**.
3. Xác nhận **Publicly accessible = No**, mã hóa, deletion protection, rồi copy `DBEndpointAddress` và `DBEndpointPort` từ Outputs mới. Nếu RDS đang khởi tạo storage sau restore, ghi nhận khả năng tăng độ trễ khi kiểm thử.
4. **Restore** dùng lại các DB role và dữ liệu đã có trong snapshot. Vào **Secrets Manager → tindy/database/api-connection**, đối chiếu `AWSCURRENT` với DB đã phục hồi. Secret dùng JSON keys `password` và `connectionString`. Nếu endpoint đổi, cập nhật host trong `connectionString` và giữ credential tương ứng với DB trong snapshot, cổng, tên DB và TLS `VerifyFull` với CA bundle. Nếu cần migration mới, đối chiếu secret của migration theo cách tương tự. Nếu credential không khớp, dừng và phục hồi quyền truy cập theo quy trình quản trị DB. Giữ secret values trong AWS.
5. **Fresh** lấy thêm `DBMasterSecretArn`. Việc chuẩn bị secrets và chạy one-off task nằm ở mục 5 sau khi runtime đã được tạo với `DesiredCount = 0`.

## 3. Tạo lại tích hợp quét PDF

1. Tạo stack `tindy-integrations` từ [integrations.yaml](../../cloudformation/integrations.yaml). Điền `MediaBucketName` từ `tindy-foundation` và `ScanAlarmEmail` là địa chỉ người nhận cảnh báo. Để trống cả `AlbMetricLoadBalancer` và `AlbMetricTargetGroup` trong lượt tạo vì runtime chưa có ALB mới. Áp dụng bộ tag vận hành ở mục 2.
2. Tạo và review Change Set. Với email được cấu hình và hai tham số ALB trống, dự kiến **11 Add** gồm GuardDuty plan/role, EventBridge rule, hai queue và hai queue policy, DLQ alarm, SNS topic/policy/subscription. Xác nhận IAM capability nếu Console yêu cầu, thực thi rồi chờ `CREATE_COMPLETE`.
3. Vào **GuardDuty → Malware Protection for S3** và mở plan mới. Xác nhận **Active**, tagging bật, cả `certificates/pdf/` và `ai-input/pdf/`. Copy `GuardDutyProtectionPlanArn` và `GuardDutyQueueUrl` từ Outputs mới.
4. Mở thư xác nhận SNS mới nhất đúng topic, bấm **Confirm subscription** và kiểm tra **SNS → Subscriptions** hiện **Confirmed**. Với `Pending confirmation`, chọn subscription hiện tại và bấm **Request confirmation** để nhận thư mới. Topic có thể giữ cùng tên sau khi dựng lại dù subscription đã mới.

## 4. Tạo lại runtime với DesiredCount = 0

Tạo stack `tindy-runtime` từ [runtime.yaml](../../cloudformation/runtime.yaml). Điền theo bảng và áp dụng bộ tag vận hành.

| Parameter | Nguồn |
| --- | --- |
| `ApiImage` | Ghép output `ApiRepositoryUri` từ Foundation với `@` và digest đã xác minh |
| `DesiredCount` | `0` |
| `VpcId`, `PublicTaskSubnetIds`, `PrivateAppSubnetIds`, `AlbSubnetCidrs`, `AlbSecurityGroupId`, `EcsSecurityGroupId` | Outputs cùng tên từ `tindy-network` |
| `CloudFrontOriginPrefixListId` | IPv4 managed prefix list `com.amazonaws.global.cloudfront.origin-facing` tại `us-east-1` |
| `CloudFrontServiceSecurityGroupId` | Để trống trong lượt tạo |
| `CloudFrontPublicHost` | `DistributionDomainName` của `tindy-edge` |
| `DatabaseConnectionSecretArn`, `JwtSigningKeySecretArn`, `DataProtectionParameterPath` | Outputs từ `tindy-foundation` |
| `OAuthEnabled`, `MediaEnabled`, `BedrockTextEnabled`, `AiPdfUploadsEnabled` | Theo manifest. Chỉ bật PDF khi schema và tích hợp quét đã sẵn sàng |
| `GoogleOAuthSecretArn`, `GitHubOAuthSecretArn`, `MediaBucketName` | Outputs từ `tindy-foundation`. Với OAuth, cả hai secret dùng keys `clientId` và `clientSecret` |
| `GuardDutyProtectionPlanArn`, `GuardDutyQueueUrl` | Outputs mới từ `tindy-integrations` |
| `DBProvisionMode` | Output của DB mới |
| `DBEndpointAddress`, `DBMasterSecretArn` | Để trống với Restore. Với Fresh, điền cả hai khi cấu hình bootstrap ở mục 5 |
| `MigrationConnectionSecretArn`, `SeedPasswordSecretArn` | Restore với cùng release để trống. Khi Restore có migration đã duyệt, chỉ điền ARN migration. Với Fresh, điền các ARN sau khi chuẩn bị secrets |

Tạo và xem Change Set. Với lượt tạo cơ bản và chưa cấu hình one-off tasks, dự kiến 12 mục `Add` gồm ECS service, task definition, IAM roles/policy, log group, ALB, listener, target group, ingress và VPC Origin. Chấp nhận IAM capability theo yêu cầu của template. Execute, chờ `CREATE_COMPLETE`, sau đó vào **CloudFront → VPC origins** và kiểm tra origin mới báo **Deployed**. Lưu `AlbDnsName`, `VpcOriginId`, `ApiTargetGroupArn` mới.

## 5. Chuẩn bị schema và chạy API

1. **Restore cùng release** dùng schema và dữ liệu từ snapshot. Bỏ qua bootstrap và seed. Nếu release mới có migration, xác minh snapshot trước thay đổi và chạy riêng migration với secret của `tindy_migrator` qua task definition được tạo khi điền `MigrationConnectionSecretArn`. Giữ Edge ở maintenance và ECS service ở 0 cho đến khi xem được kết quả.
2. **Fresh** chạy [prepare-runtime-secrets.ps1](../../scripts/prepare-runtime-secrets.ps1) khi service có 0 desired/running/pending tasks. Script giữ nguyên secret đã có `AWSCURRENT`, nên đối chiếu DB host và cấu hình TLS nếu dùng lại Foundation. Với bản đầy đủ, giữ `AiPdfUploadsEnabled = false` trong lúc schema đang được chuẩn bị.

   ```powershell
   .\scripts\prepare-runtime-secrets.ps1 -AwsProfile tindy-admin | Format-List *
   ```

   Cập nhật runtime qua Change Set với `DBEndpointAddress`, `DBMasterSecretArn`, `MigrationConnectionSecretArn` và `SeedPasswordSecretArn` từ kết quả. Giữ `DesiredCount = 0`. Trong **ECS → tindy-runtime → Tasks → Run new task**, chọn **Fargate**, public task subnets từ `tindy-network`, `MigrationSecurityGroupId` và bật **Assign public IP** để đi outbound. Chạy từng definition từ Outputs theo thứ tự `DbBootstrapTaskDefinitionArn` → `MigrationTaskDefinitionArn` → `SeedTaskDefinitionArn` nếu cần dữ liệu mẫu. Mỗi task chạy một lần, có thể hiện `Stopped` sau khi hoàn thành. Kiểm tra **exit code 0** và log hoàn tất trước khi chạy task tiếp theo. Đối chiếu migration ID, catalog và dữ liệu mẫu sau seed.
3. Khi DB đã sẵn sàng, tìm `CloudFront-VPCOrigins-Service-SG` trong **EC2 → Security Groups**, lọc đúng VPC của Tindy và lấy **ID hiện tại**. Tạo Change Set của runtime, điền ID vào `CloudFrontServiceSecurityGroupId` và đặt `DesiredCount = 1`. Khi chỉ đổi hai trường này, kỳ vọng `AlbIngressFromCloudFront` được thay thế và `ApiService` được sửa tại chỗ. Nếu bật PDF sau Fresh, review thay đổi task definition trong Change Set riêng khi schema, GuardDuty và queue đã sẵn sàng.
4. Chờ `UPDATE_COMPLETE`. Trong **ECS → tindy-api → Health and metrics**, xác nhận 1 running, deployment **Success** và target ALB **Healthy**. Đối chiếu image của task đang chạy. Nếu task khởi động lỗi, xem ECS **Events**, **Stopped reason**, log và health check trước khi mở Edge.

## 6. Gắn lại alarm và mở CloudFront

1. Trong `tindy-runtime → Resources → InternalAlb`, lấy phần của ARN bắt đầu bằng `app/`. Từ output `ApiTargetGroupArn`, lấy phần bắt đầu bằng `targetgroup/`.
2. Tạo Change Set cho `tindy-integrations` với hai giá trị mới vào `AlbMetricLoadBalancer` và `AlbMetricTargetGroup`. Giữ bucket và email. Dự kiến thêm ba alarm ALB/API và cập nhật `ScanAlarmTopicPolicy`. Chờ `UPDATE_COMPLETE`, kiểm tra bốn alarm trong CloudWatch, metric dimensions hướng đến ALB/target group mới và action về SNS topic đã xác nhận.
3. Tạo Change Set cho `tindy-edge` với `EdgeMode = live`, `AlbDnsName` và `VpcOriginId` từ runtime mới. Giữ `FrontendBucketName`. Kỳ vọng đúng `EdgeDistribution → Modify → Replacement = False`. Execute, chờ `UPDATE_COMPLETE` và CloudFront **Deployed**. Xác nhận distribution ID và hostname khớp manifest.

## 7. Nghiệm thu trước khi bàn giao

| Kiểm tra | Bằng chứng cần ghi |
| --- | --- |
| Frontend và API | Trang chủ và `/login` tải được, logo hiển thị, `/api/health/ready` trả `200` với JSON `Healthy` trên hostname cũ |
| Auth | Đăng nhập bằng tài khoản Tindy, Google và GitHub. Kiểm tra chuyển về đúng hostname HTTPS và mở được trang cần đăng nhập |
| Dữ liệu | Đối chiếu tin nhắn hoặc bản ghi đã chọn trước snapshot, dữ liệu profile/project và file media liên quan. Kiểm tra schema phù hợp release |
| Chat | Hai phiên đăng nhập thấy tin nhắn mới. DevTools xác nhận WebSocket `101 Switching Protocols` |
| Media và AI | Kiểm tra certificate PDF và AI Studio bằng file mẫu. Với AI PDF, quan sát `scanning → clean`, tag GuardDuty `NO_THREATS_FOUND` cho đúng object/version, rồi mới chạy trích xuất. Ghi kết quả AI Text, PDF và DLQ. Đối chiếu trạng thái pending cũ trước khi dùng lại |
| Vận hành | Kiểm tra alarms, SNS, thực tế chi phí và thời gian mở hệ thống. Ghi riêng các ca chưa chạy hoặc chưa có bằng chứng |

Trước lần **Deploy backend** tiếp theo, nếu API execution role hoặc task role đổi sau khi dựng lại, đối chiếu `BackendApiExecutionRoleName` và `BackendApiTaskRoleName` của `tindy-foundation` với hai tên mới. Cập nhật qua Change Set đã review để quyền `iam:PassRole` trỏ đúng hai role. Có thể lấy tên từ ECS task definition hoặc Physical ID của `ApiExecutionRole` và `ApiTaskRole` trong stack runtime.

Ghi lại snapshot đã dùng, image digest, migration ID, thời điểm hoàn tất và kết quả từng ca. Nếu ca bắt buộc lỗi sau khi mở traffic, báo người điều phối và đưa Edge về `maintenance` trong cửa sổ xử lý.
