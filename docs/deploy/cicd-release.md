# Phát hành Tindy qua CI/CD

Dùng runbook này khi Tindy đang chạy và cần đưa thay đổi backend, frontend hoặc schema PostgreSQL lên AWS. Nếu đã teardown, dựng lại các stack theo [runbook Redeploy](redeploy.md).

| Thay đổi | Thứ tự thực hiện |
| --- | --- |
| Chỉ sửa backend, thư mục migration giữ nguyên | Backend CI → Deploy backend (`deploy`) → kiểm tra API |
| Chỉ sửa frontend | Frontend CI → Deploy frontend (`deploy`) → kiểm tra web |
| Sửa cả backend và frontend | CI cả hai repo → deploy và xác minh backend → deploy và xác minh frontend. Bản API mới cần phục vụ được cả frontend đang chạy trong lúc chuyển phiên bản |
| Thêm hoặc thay đổi file migration | Backend CI → chuẩn bị image → snapshot RDS → chạy task migration → cập nhật baseline → deploy backend → deploy frontend nếu có thay đổi liên quan |

## 1. Chuẩn bị release trên GitHub

1. Commit và push các file liên quan lên feature branch trong repo tương ứng. Tạo PR vào `main`, đợi **Backend CI / verify** hoặc **Frontend CI / verify** xanh rồi merge. Kiểm tra CI của commit trên `main` trước khi phát hành.
2. Mở commit đã duyệt trên `main` và copy SHA đầy đủ 40 ký tự. Khi chạy CD, luôn chọn workflow từ `main`. Để trống `release_sha` sẽ dùng commit `main` của lượt chạy đó. Điền SHA cụ thể khi cần phát hành đúng một bản đã duyệt, đặc biệt với migration.
3. Hai workflow CD được chạy bằng **Actions → tên workflow → Run workflow**. Merge vào `main` kích hoạt CI. Người vận hành chủ động chạy CD sau khi CI xanh. [Chạy workflow thủ công trên GitHub](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

### Biến GitHub Actions

Nếu đổi repo, role hoặc tài nguyên AWS, đối chiếu tại **Settings → Secrets and variables → Actions → Variables → Repository variables** của repo tương ứng. Lấy giá trị từ Outputs của stack trong `us-east-1`.

| Repo | Tên biến | Nguồn |
| --- | --- | --- |
| Backend | `TINDY_BACKEND_DEPLOY_ROLE_ARN` | `tindy-foundation` → `BackendDeployRoleArn` |
| Frontend | `TINDY_FRONTEND_DEPLOY_ROLE_ARN` | `tindy-foundation` → `FrontendDeployRoleArn` |
| Frontend | `TINDY_FRONTEND_BUCKET` | `tindy-foundation` → `FrontendBucketName` |
| Frontend | `TINDY_FRONTEND_DISTRIBUTION_ID` | `tindy-edge` → `DistributionId` |
| Frontend | `TINDY_FRONTEND_HOST` | `tindy-edge` → `DistributionDomainName`, chỉ điền hostname |

GitHub Actions dùng OIDC để assume role. Sau khi dựng lại `tindy-runtime`, đối chiếu hai tên role ECS trong các tham số `BackendApiExecutionRoleName` và `BackendApiTaskRoleName` của Foundation trước lượt deploy backend tiếp theo. Xem [runbook Redeploy](redeploy.md#7-nghiệm-thu-trước-khi-bàn-giao).

## 2. Deploy backend khi schema giữ nguyên

1. Xác nhận service `tindy-runtime` → `tindy-api` đã ổn định, target ALB `Healthy` và Edge ở `live`. Ghi lại task definition revision và image URI đang chạy để đối chiếu sau deploy.
2. Vào repo backend → **Actions → Deploy backend → Run workflow**. Chọn `main`, đặt `mode = deploy`, điền `release_sha` đã duyệt rồi bấm **Run workflow**.
3. Workflow kiểm tra migration baseline, đưa image lên ECR hoặc dùng digest đã có, đăng ký ECS task definition mới và cập nhật service. Trong **Summary**, đối chiếu `Release commit`, `ECR image` và `Verified ECS revision`. Nếu Summary báo image đã chạy và ready, đối chiếu với revision hiện hành trên ECS.
4. Kiểm tra ECS service ổn định, ALB target `Healthy` và gọi readiness qua CloudFront. Dùng hostname hiện hành từ `tindy-edge`.

   ```powershell
   $edgeHost = 'd3aaob529jaggi.cloudfront.net'
   curl.exe -i "https://$edgeHost/api/health/ready"
   ```

   Kỳ vọng HTTP `200` và JSON `status = Healthy`. Thử chức năng đã sửa trên web. Với lỗi rollout, đọc **Summary**, ECS **Events**, lý do task dừng và log `/ecs/tindy-runtime`. Nếu có `Rollback verified`, đối chiếu revision cũ và readiness. Nếu gate báo migration khác baseline, dùng mục 3.

## 3. Phát hành backend có migration PostgreSQL

### 3.1. Chuẩn bị migration và image

1. Tạo migration trong repo backend khi thay đổi schema. Review `Up`, `Down`, model snapshot và các thao tác ảnh hưởng dữ liệu. Test trên PostgreSQL local hoặc môi trường thử nghiệm với schema trước thay đổi. Commit migration cùng thay đổi entity/configuration. Xem `docs/guide/DATABASE_SETUP.md` trong repo backend để lấy lệnh EF Core cho máy local.
2. Kiểm tra API đang chạy vẫn tương thích với schema mới trong quá trình chuyển phiên bản và khi ECS rollback. Nếu dự định đổi tên hoặc xóa cột mà API cũ còn dùng, chia release theo thứ tự thêm cấu trúc mới → chuyển code/dữ liệu → bỏ cấu trúc cũ ở release sau.
3. Merge release đã qua CI vào `main` và ghi SHA. Trong **Deploy backend → Run workflow**, chọn `main`, `mode = prepare-schema` và điền chính xác `release_sha`. Xác nhận `prepare-schema` có trong dropdown. Nếu thiếu, đưa workflow và script hỗ trợ `prepare-schema` đã review lên `main` trước khi tiếp tục.
4. Mở **Summary**, lưu `Release commit`, `Migration tree` và `ECR image` dạng `<repository>@sha256:…`. `prepare-schema` cần service đang ổn định và readiness công khai trả `200`. Lượt chạy này chỉ chuẩn bị image. `Migration tree` là Git tree hash của `src/Tindy.Infrastructure/Persistence/Migrations`, khác với migration ID EF ghi trong RDS.

### 3.2. Backup và chạy migration một lần

1. Chọn cửa sổ thực hiện, dừng các lượt deploy/teardown song song. Ghi task definition revision, image URI theo digest của API đang chạy và migration ID đã áp dụng gần nhất. Nếu cần đóng băng ghi dữ liệu để giữ điểm khôi phục nhất quán, phối hợp dừng ghi, upload mới và chờ xử lý tác vụ còn lại trước khi lấy snapshot. `Deploy backend` cần ECS đang chạy và Edge phục vụ readiness. Nếu đóng Edge để bảo trì, kiểm tra lại điều kiện mở Edge trước khi chạy CD.
2. Tạo snapshot trong **Aurora and RDS → Databases → `tindy-database-postgres` → Actions → Take snapshot**, ví dụ `tindy-before-schema-<short-sha>-<yyyymmddhhmm>`. Chờ **Snapshots → Manual** báo `Available`, xác nhận snapshot mã hóa và thuộc đúng DB hiện tại. Nếu dùng **Backup Tindy**, làm theo mục Backup trong [runbook lifecycle](../lifecycle.md#backup). Nhập digest đang chạy và migration ID trước thay đổi. Lưu snapshot ID/ARN và thời điểm tạo. [Tạo snapshot RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_CreateSnapshot.html)
3. Trong **CloudFormation → `tindy-runtime` → Outputs**, lấy `MigrationTaskDefinitionArn`. Nếu thiếu output sau lượt Restore, chuẩn bị `MigrationConnectionSecretArn` trỏ đến secret của DB role migration và đến đúng RDS hiện tại. Dùng Change Set để bật task definition migration. Review `ApiService` và image API đang chạy trước khi áp dụng Change Set vì CloudFormation có thể đang ghi revision cũ hơn revision do CD deploy. Tiếp tục khi thay đổi đã được đối chiếu và API hiện hành vẫn đúng release. [Template runtime](../../cloudformation/runtime.yaml)
4. Trong **ECS → Task definitions**, mở revision theo `MigrationTaskDefinitionArn`, tạo revision mới và chỉ đổi **Image URI** của container `migration` thành URI theo digest từ `prepare-schema`. Giữ command `migrate-db`, execution role và cấu hình log. Kiểm tra secret migration có JSON key `connectionString` trỏ tới đúng DB, dùng credential migration và TLS `VerifyFull`. Giữ secret values trong AWS.
5. Vào **ECS → Clusters → `tindy-runtime` → Tasks → Run new task**. Chọn revision migration mới, **Fargate**, số lượng `1`, VPC Tindy, `PublicTaskSubnetIds` và `MigrationSecurityGroupId` từ `tindy-network`. Bật **Assign public IP** theo cấu hình task migration của Tindy. Chạy riêng task này. Quy trình phát hành vào DB hiện tại chỉ cần `migrate-db`. Bootstrap và seed dành cho luồng Fresh khi dựng DB mới.
6. Khi task `Stopped`, mở **Containers → migration → Details** và kiểm tra `Exit code = 0` cùng image digest. Mở **Logs**, tìm `Database migration complete` và đối chiếu `Latest migration` với migration dự kiến. Ghi task ARN, migration ID và log hoàn tất. Nếu lỗi hoặc migration ID sai, kiểm tra lịch sử migration và trạng thái schema trước khi quyết định thử lại.
7. Gọi `/api/health/ready` và thử các chức năng đang chạy có sử dụng bảng/cột vừa đổi. Chỉ cập nhật baseline khi migration hoàn tất và API cũ đã được xác minh tương thích.

### 3.3. Cập nhật baseline rồi deploy đúng image

1. Trong repo backend, mở PR sửa `scripts/deploy-backend.sh`. Đặt `known_migrations` bằng **Migration tree** từ `prepare-schema`. Cập nhật digest trong `baseline_fallback_image` theo **image API cũ đang chạy** đã được xác minh với schema mới. Giữ định dạng URI hiện có trong script.
2. Ghi trong PR snapshot ID và thời điểm tạo, release SHA, image digest đã chuẩn bị, task ARN và migration ID mới. Merge khi bằng chứng đã được đối chiếu và CI xanh.
3. Chạy lại **Deploy backend** từ `main` với `mode = deploy`. Điền **cùng `release_sha` đã chạy `prepare-schema`**. Workflow lấy script có baseline mới từ commit chạy trên `main`, rồi chọn source theo `release_sha` đã nhập. Đối chiếu digest trong Summary với image migration, revision ECS mới và kết quả smoke test. Nếu FE đi cùng, làm mục 4 sau khi backend đã đạt các kiểm tra.
4. Nếu rollout API lỗi, kiểm tra rollback ECS và xác minh lại API cũ trên schema mới. Rollback ECS khôi phục phiên bản API. Nếu cần phục hồi DB, quyết định giữa phát hành bản sửa tiếp theo hoặc restore snapshot. Restore tạo một DB instance từ thời điểm snapshot. Đối chiếu các ghi phát sinh sau thời điểm đó và dữ liệu liên quan trước khi chuyển kết nối ứng dụng. [Khôi phục RDS từ snapshot](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_RestoreFromSnapshot.html)

## 4. Deploy frontend

1. Vào repo frontend → **Actions → Deploy frontend → Run workflow**. Chọn `main`, `mode = deploy`, điền `release_sha` đã duyệt và bấm **Run workflow**. `verify-oidc` dùng để kiểm tra AWS role khi mới cấu hình hoặc đổi role.
2. Chờ cả `build` và `publish` xanh. Workflow build Vite với API cùng origin, upload assets trước rồi upload `index.html`, chờ CloudFront invalidation hoàn tất và kiểm tra nội dung `/`, `/login` và bundle JavaScript qua CloudFront.
3. Mở web bằng cửa sổ InPrivate, kiểm tra trang đăng nhập, logo và phần vừa sửa. Nếu logo vỡ dù `/logo.png` trả `200`, kiểm tra `dist/logo.png` và response có phải PNG thật. `public/logo.png` được quản lý bằng Git LFS và từng có lần lên S3 dưới dạng pointer 131 byte. Workflow trong checkout dùng checkout mặc định, nên cần kiểm tra logo sau deploy cho đến khi đã xác minh build lấy đúng nội dung LFS.
4. Nếu cần quay lại FE cũ, chọn commit `main` đã phát hành thành công và tương thích với API đang chạy, rồi chạy lại `deploy` với SHA đó. Sau khi hoàn tất, kiểm tra lại qua CloudFront và ghi link của cả lượt deploy lỗi lẫn lượt phục hồi.
