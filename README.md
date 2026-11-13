# Nếp Nhà Design

![Logo Nếp Nhà Design](nep_nha_design/logo.png)

Trợ lý ChatGPT tiếng Việt trong SketchUp. Hỗ trợ đọc thông tin mô hình, chụp viewport,
tạo Tag và vật liệu. Xem hướng dẫn cài đặt trong [HUONG_DAN.txt](nep_nha_design/HUONG_DAN.txt).

## Đưa mã nguồn lên GitHub lần đầu

1. Giải nén gói mã nguồn. Trong GitHub Desktop, chọn **File → Add local repository**,
   chọn thư mục chứa README này, rồi chọn **Create a repository** nếu được hỏi.
   Giữ README và tệp cấu hình đi kèm. Commit các tệp lên nhánh chính nếu chúng đang
   ở tab **Changes**.
2. Chọn **Publish repository**. Đặt tên, ví dụ `nep-nha-design`. Bỏ chọn
   **Keep this code private** nếu đồng ý công khai mã nguồn và logo. Trợ lý đọc
   GitHub Releases công khai để cập nhật trên máy người dùng.
3. Kiểm tra kho GitHub đã có `.github/workflows/release.yml`. Trong GitHub Desktop,
   mở **History**, bấm chuột phải vào commit cần phát hành, chọn **Create Tag**
   và đặt tên `v1.4.2`. Bấm **Push origin** để đẩy tag lên GitHub.
4. Trên GitHub, kiểm tra tab **Actions**. Khi tác vụ phát hành hoàn tất, tab
   **Releases** sẽ có `v1.4.2` và tệp `Nep-Nha-Design-Tro-Ly-ChatGPT-v1.4.2.rbz`.

Nếu chỉ muốn công khai gói cài, có thể dùng kho phát hành công khai riêng và giữ
mã nguồn ở kho riêng tư. Khi đó, đăng tệp RBZ vào một Release ổn định của kho
công khai theo đúng tên và tag. Workflow trong gói này phát hành vào chính kho
chứa mã nguồn.

## Kết nối nút cập nhật trong SketchUp

1. Mở **Extensions → Nếp Nhà Design → Mở Trợ lý AI → Cập nhật tiện ích**.
2. Nhập `chủ-kho/tên-kho`. Từ v1.4.2 cũng có thể dán URL của kho.
3. Bấm **Kiểm tra cập nhật**. Nếu đang dùng v1.4.1, chọn **Cập nhật lên 1.4.2**.
4. Lưu bản vẽ, đóng rồi mở lại SketchUp. Kiểm tra số phiên bản trong tiêu đề.

Nếu SketchUp từ chối cài, kiểm tra chính sách nạp tiện ích của máy. Gói này chưa
được ký số.

## Phát hành các phiên bản sau

Cập nhật số phiên bản trong các tệp mà `scripts/build_rbz.py` kiểm tra, commit,
rồi đẩy tag `vX.Y.Z` tương ứng. GitHub Actions đóng gói RBZ, kiểm tra và đính kèm
tệp vào GitHub Release. Trong SketchUp, bấm **Kiểm tra cập nhật → Cập nhật** khi
có bản mới. Để đóng gói cục bộ, chạy `python scripts/build_rbz.py`.
