# Nếp Nhà Design

![Logo Nếp Nhà Design](nep_nha_design/logo.png)

Mã nguồn trợ lý kiến trúc chạy trong SketchUp. Thư mục làm việc dùng chung trên
Windows là `E:\My Drive\14. SU MCP` và đồng thời là Git checkout của
`Shmily1905/nep_nha_design`.

- `nep_nha_design.rb` và `nep_nha_design/` chứa mã nguồn extension.
- `design-skills/` chứa các quy tắc thiết kế dùng chung.
- `nep_nha_design/design-skills/` chứa skill mặc định đi kèm gói cài đặt.
- `scripts/build_rbz.py` kiểm tra phiên bản và đóng gói extension.
- `releases/` chứa gói RBZ cục bộ và không được commit.

## Làm việc bằng Codex hoặc Antigravity

Mở `E:\My Drive\14. SU MCP` làm thư mục dự án. Trong Antigravity App, thêm
thư mục này vào Project và chọn Local mode. Cả hai trợ lý phải đọc
`GEMINI.md` trước khi sửa.

Chỉ để một trợ lý sửa dự án tại một thời điểm. Đợi Google Drive đồng bộ trước
khi chuyển lượt. Khi bàn giao, ghi các file đã sửa và cách kiểm tra.

## Kiểm tra và phát hành

Chạy kiểm tra đóng gói cục bộ bằng lệnh sau.

```powershell
python scripts/build_rbz.py --output-dir releases
```

Sau khi kiểm tra, commit và push nhánh `main`. Để phát hành, cập nhật đồng bộ
số phiên bản, tạo tag `vX.Y.Z` trên commit cần phát hành rồi push tag.
GitHub Actions tạo gói RBZ và GitHub Release. Nút cập nhật trong SketchUp đọc
Release mới nhất.

## Kho skill dùng chung

Trong SketchUp, mở **Extensions → Nếp Nhà Design → Chọn kho skill dùng chung**
và chọn `E:\My Drive\14. SU MCP\design-skills`. Trợ lý đọc lại các file
Markdown ở mỗi lượt. Khi Drive ngoại tuyến, trợ lý dùng bản nội dung đã lưu
cục bộ sau lần đọc thành công gần nhất.

Extension đã cài chạy từ thư mục Plugins của SketchUp. Python, log và cấu hình
MCP nằm tại `%LOCALAPPDATA%\NepNhaDesign`.
