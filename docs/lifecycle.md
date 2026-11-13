# Vận hành Backup, Teardown và Redeploy

## Bật workflow

1. Tạo Change Set cho `tindy-foundation` với template mới và `LifecycleWorkflowsEnabled=true`. Dùng giá trị hiện tại cho các tham số khác, gồm `GitHubOidcProviderMode` và `FrontendDeployDistributionId`.
2. Kiểm tra Change Set dự kiến chỉ thêm `LifecycleRole`. Thực thi trong AWS Console và chờ `UPDATE_COMPLETE`.
3. Copy output `LifecycleRoleArn` vào repository variable `TINDY_LIFECYCLE_ROLE_ARN` của `tindy-infrastructure`. Cả ba workflow chạy thủ công từ `main`.

## Backup

1. Chốt một người điều phối và cửa sổ bảo trì. Xác nhận các lượt deploy backend, frontend và cập nhật hạ tầng đã kết thúc. Trong suốt cửa sổ này, điều phối viên giữ quyền điều phối các thao tác Console và báo team tạm dừng chạy deploy. GitHub chỉ serialize ba workflow lifecycle trong cùng repo.
2. Freeze ghi dữ liệu, upload và yêu cầu AI mới. Drain và đối chiếu kết quả GuardDuty, SQS, DLQ và trạng thái nghiệp vụ còn pending. Các số liệu queue là xấp xỉ. Xác nhận những kiểm tra này trước khi nhập `BACKUP TINDY`.
3. Chạy **Backup Tindy** với digest API đang chạy và ID migration EF đã xác minh. Chờ Summary có snapshot `available` và `Encrypted: true`. Lưu snapshot ID/ARN cùng commit, image, trạng thái dữ liệu, distribution ID/domain và thông tin lưu trữ media trong biên bản vận hành. Chỉ ghi thông tin tham chiếu cho secrets và key ring.

## Teardown

1. Kiểm tra biên bản Backup và xác nhận snapshot được tạo trong cửa sổ hiện tại, sau khi freeze writes. Đối chiếu media và tham chiếu phục hồi. Giữ Golden Snapshot và hai snapshot gần nhất đã xác minh.
2. Tạo và review Change Set để đưa `tindy-edge` sang `maintenance`. Chờ CloudFront `Deployed`. Kiểm tra trang bảo trì theo runbook và giữ nguyên distribution ID/domain.
3. Chạy **Teardown Tindy** với `TEARDOWN TINDY` và ID từ Backup. Kiểm tra Summary. Workflow đối chiếu snapshot với DB vật lý hiện tại, kiểm tra queue/DLQ và xác nhận CloudFront đã gỡ VPC Origin và trả HTTP 503.
4. Trong AWS Console, xóa `tindy-runtime` trước, chờ hoàn tất và kiểm tra ECS, ALB và VPC Origin đã được dọn. Sau đó, review Change Set của `tindy-database` để tắt RDS deletion protection. Chờ update hoàn tất và xác nhận snapshot vẫn `Available` trước khi xóa stack DB. Cuối cùng, xác minh queue/DLQ và nghiệp vụ còn an toàn để xóa `tindy-integrations`. Giữ `tindy-foundation`, `tindy-network`, `tindy-edge`, media và snapshot.
5. Nếu gặp lỗi, dừng ở stack đó và kiểm tra Events. Sau khi hoàn tất, đối chiếu inventory và billing.

## Redeploy

1. Kiểm tra budget, ECR, media, secrets và Data Protection key ring. Chạy **Redeploy Tindy** với `REDEPLOY TINDY`, digest API đã xác minh và mode `Restore` hoặc `Fresh`. Với Restore, nhập ID manual snapshot. Với Fresh, để trống snapshot ID.
2. Dùng kết quả preflight để tạo và review Change Set cho database. Restore dùng đúng snapshot đã chọn và kiểm tra lại endpoint, quyền DB, secrets và dữ liệu. Fresh dùng DB mới, chạy migration và seed theo quy trình đã duyệt. Chỉ chạy migration trên Restore khi release có migration mới, theo quy trình backup và migration của backend.
3. Dựng runtime và integrations, kiểm tra readiness, queue và GuardDuty. Cập nhật `tindy-edge` sang `live` sau khi backend sẵn sàng. Xác nhận distribution ID/domain giữ nguyên, rồi chạy các ca nghiệm thu STEP 15.
