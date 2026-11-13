# Quy trình concept kiến trúc Nếp Nhà

## Mục tiêu và thứ tự ưu tiên

- Tạo concept 3D có hình khối, tỷ lệ và ngôn ngữ kiến trúc hợp lý; không cố hoàn thiện toàn bộ công trình trong một lần dựng.
- Ưu tiên dữ liệu theo thứ tự: kích thước người dùng xác nhận; đường bao mặt bằng đã duyệt; quy chuẩn Nếp Nhà đã lưu; đặc trưng nhìn thấy trong ảnh tham chiếu; giả định concept được người dùng cho phép.
- Không dùng ảnh tham chiếu để suy ra kích thước tuyệt đối khi ảnh không có mốc tỷ lệ đáng tin cậy. Ảnh tham chiếu chủ yếu quyết định tỷ lệ tương đối, nhịp điệu, phong cách, chi tiết và vật liệu.
- Không tự thêm vòm, cột, lam, phào, mái, bồn cây hoặc họa tiết chỉ để lấp khoảng trống. Mỗi chi tiết phải có căn cứ từ yêu cầu, ảnh tham chiếu, thư viện được duyệt hoặc nguyên tắc Nếp Nhà đã lưu.

## Dữ liệu phải chốt trước khi dựng

Trước giai đoạn hình học 3D, xác định và báo lại:

1. Đường bao tường ngoài, cạnh mặt tiền và một kích thước mốc.
2. Cao độ nền, chiều cao tầng hoặc chiều cao đến mép mái.
3. Loại mái, hướng dốc, độ dốc và độ đua mái nếu đã biết.
4. Vai trò của từng ảnh tham chiếu: hình khối, mái, mặt đứng, vật liệu hay chi tiết.
5. Những yếu tố phải giữ và những yếu tố tuyệt đối không sao chép.
6. Danh sách kích thước đã biết, kích thước suy ra và giả định cần người dùng duyệt.

Nếu thiếu dữ liệu làm thay đổi đáng kể tỷ lệ, loại mái hoặc bố cục mặt đứng, hỏi trước khi dựng. Với concept cho phép ước lượng, chỉ dùng giả định sau khi đã nêu rõ.

## Phân tích ảnh tham chiếu thành dữ liệu

Với mỗi ảnh, lập ghi chú nội bộ theo các trường sau trước khi tạo hình học:

- `vai_tro`: hình khối, mái, mặt đứng, vật liệu hoặc chi tiết.
- `dac_trung_quan_sat`: điều thực sự nhìn thấy trong ảnh.
- `ap_dung_cho`: bộ phận nào của công trình hiện tại.
- `ty_le_tuong_doi`: tỷ lệ đặc-rỗng, nhịp, độ mảnh, độ sâu, độ đua hoặc kích thước viên/vân nếu có căn cứ.
- `vat_lieu`: loại vật liệu, màu, độ bóng, độ nhám, hướng vân và kích thước module nếu xác định được.
- `khong_sao_chep`: yếu tố không phù hợp mặt bằng, khí hậu, kết cấu hoặc yêu cầu dự án.
- `do_tin_cay`: cao, trung bình hoặc thấp; nêu lý do khi không phải mức cao.

Phân biệt rõ quan sát và suy luận. Không biến đặc điểm xuất hiện trong một ảnh thành quy tắc chung của Nếp Nhà. Khi nhiều ảnh mâu thuẫn, hỏi thứ tự ưu tiên hoặc trình bày phương án lựa chọn.

## Các cổng duyệt bắt buộc

### 1. Đường bao 2D

- Chỉ vẽ đường bao tường ngoại thất và các góc lồi, lõm quan trọng.
- Hiện kích thước bao, cạnh mặt tiền, mốc tỷ lệ và sai số hoặc giả định.
- Chưa tạo cửa, cột trang trí hay vật liệu ở bước này.

### 2. Massing trắng

- Dựng nền, tường và các khối mái chính bằng vật liệu đơn sắc.
- Kiểm tra tỷ lệ tổng thể, quan hệ các khối, cao độ và khoảng hiên.
- Không dùng chi tiết trang trí để che lỗi tỷ lệ hình khối.

### 3. Mái

- Chốt loại mái, giao mái, cao độ mép mái, đỉnh mái, độ dốc và độ đua.
- Dùng công cụ mái phù hợp; không thay mái hai dốc bằng mái hông hoặc ngược lại chỉ vì công cụ đang sẵn có.
- Kiểm tra thoát nước, giao mái, khoảng che hiên và quan hệ mái với cửa.

### 4. Nhịp mặt đứng và lỗ mở

- Chia nhịp theo công năng và cấu tạo trước khi thêm trang trí.
- Cửa đi, cửa sổ, cột và mảng tường phải tạo được thứ bậc chính-phụ, tỷ lệ đặc-rỗng và trục nhìn hợp lý.
- Không lặp một chi tiết trên mọi nhịp khi ảnh tham chiếu không chứng minh chủ ý đó.

### 5. Chi tiết và thư viện

- Ưu tiên component, profile hoặc family đã được duyệt thay vì vẽ lại bằng khối gần đúng.
- Giữ đúng điểm neo, hướng đặt, kích thước cho phép co giãn và tên nhóm của tài sản thư viện.
- Chi tiết mới phải phù hợp tỷ lệ công trình và có khả năng thi công ở mức concept.

### 6. Vật liệu

- Chỉ áp vật liệu sau khi hình khối và mặt đứng đã được duyệt.
- Dùng texture có kích thước thực, hướng vân đúng và đường ron liên tục qua các mặt cần liên tục.
- Không dùng màu phẳng để báo là đã hoàn thiện texture. Nếu chưa có file texture phù hợp, báo thiếu tài sản thay vì giả vờ hoàn thiện.

Sau mỗi cổng, chụp viewport, nêu các kích thước chính, giả định còn lại và chờ xác nhận trước khi chuyển sang cổng tiếp theo.

## Tổ chức model

- Group hoặc component theo loại: sàn, tường, mái, cửa đi, cửa sổ, cột, phào, bồn cây, cảnh quan và nội thất.
- Không để raw geometry của hai bộ phận khác loại dính vào nhau.
- Đặt tên có nghĩa và giữ trục component, điểm neo cùng hướng mặt trước nhất quán.
- Mỗi bước chỉnh sửa phải là một operation có thể Undo. Không xóa hoặc thay thế phần đã duyệt nếu chưa nói rõ phạm vi sửa.

## Kiểm tra trước khi báo hoàn thành

- So kích thước bao model với mặt bằng và mốc tỷ lệ.
- Kiểm tra cao độ nền, tường, lanh tô, mép mái và đỉnh mái.
- Kiểm tra mặt đảo, cạnh thừa, hình học rời, nhóm rỗng và đối tượng trùng.
- Kiểm tra cửa có nằm đúng mặt tường; mái không xuyên tường; cột, phào và lam không lơ lửng.
- Kiểm tra tên group, category và vật liệu; texture phải đúng tỷ lệ và hướng.
- Chụp ít nhất góc mặt tiền và góc chéo để đánh giá hình khối. Nêu rõ phần nào mới là concept hoặc còn cần hoàn thiện thủ công.

## Học từ phản hồi

- Không tự động biến mọi câu chat thành quy tắc lâu dài.
- Sau một phản hồi có giá trị tái sử dụng, đề xuất một bài học ngắn theo dạng: điều kiện áp dụng; quy tắc; ngoại lệ; ví dụ đúng; ví dụ sai.
- Chỉ lưu vào kho skill sau khi người dùng xem và xác nhận. Không lưu kích thước chỉ đúng cho một dự án thành chuẩn chung.
