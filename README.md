# Nếp Nhà Design

![Logo Nếp Nhà Design](nep_nha_design/logo.png)

Trợ lý ChatGPT tiếng Việt trong SketchUp. Hỗ trợ đọc thông tin mô hình, chụp viewport,
tạo Tag và vật liệu. Xem hướng dẫn cài đặt trong [HUONG_DAN.txt](nep_nha_design/HUONG_DAN.txt).

## Đưa mã nguồn lên GitHub lần đầu

1. Giải nén gói mã nguồn. Trong GitHub Desktop, chọn **File → Add local repository**,
   chọn thư mục chứa README này, rồi chọn **Create a repository** nếu được hỏi.
   Giữ README và tệp cấu hình đi kèm. Commit các tệp lên nhánh chính nếu chúng đang
   ở tab **Changes**.
2. Chọn **Publish repository**. Đặt tên, ví dụ `nep-nha-design`. Repository có
   thể để **Private**. Từ v1.4.3, trợ lý đọc Release riêng tư bằng fine-grained
   token chỉ có quyền `Contents: read`.
3. Kiểm tra kho GitHub đã có `.github/workflows/release.yml`. Trong GitHub Desktop,
   mở **History**, bấm chuột phải vào commit cần phát hành, chọn **Create Tag**
   và đặt tên `v1.4.3`. Bấm **Push origin** để đẩy tag lên GitHub.
4. Trên GitHub, kiểm tra tab **Actions**. Khi tác vụ phát hành hoàn tất, tab
   **Releases** sẽ có `v1.4.3` và tệp `Nep-Nha-Design-Tro-Ly-ChatGPT-v1.4.3.rbz`.

## Kết nối nút cập nhật trong SketchUp

1. Mở **Extensions → Nếp Nhà Design → Mở Trợ lý AI → Cập nhật tiện ích**.
2. Nhập `chủ-kho/tên-kho`, rồi bấm **Tạo mã đăng nhập**.
3. Trên GitHub, chọn đúng repository và chỉ cấp `Contents: read`. Sao chép token,
   dán vào trợ lý và bấm **Lưu đăng nhập**.
4. Tiện ích lưu token trong Windows Credential Manager hoặc macOS Keychain và tự
   kiểm tra cập nhật mỗi khi mở trợ lý. Khi có bản mới, bấm **Cập nhật lên X.Y.Z**.
5. Lưu bản vẽ, đóng rồi mở lại SketchUp. Kiểm tra số phiên bản trong tiêu đề.

Token không được ghi vào repository hoặc tệp cấu hình. Có thể thu hồi token trên
GitHub hoặc bấm **Đăng xuất GitHub** trong trợ lý.

Nếu SketchUp từ chối cài, kiểm tra chính sách nạp tiện ích của máy. Gói này chưa
được ký số.

## Phát hành các phiên bản sau

Cập nhật số phiên bản trong các tệp mà `scripts/build_rbz.py` kiểm tra, commit,
rồi đẩy tag `vX.Y.Z` tương ứng. GitHub Actions đóng gói RBZ, kiểm tra và đính kèm
tệp vào GitHub Release. Trong SketchUp, bấm **Kiểm tra cập nhật → Cập nhật** khi
có bản mới. Để đóng gói cục bộ, chạy `python scripts/build_rbz.py`.
