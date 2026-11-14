# Dựng hình bằng Large Tool Set — SketchUp 2024

## Lập trình tự dựng

1. Đọc mặt bằng, mặt đứng và mặt cắt. Chốt mốc tọa độ, đơn vị, cao độ, trục, khổ bao và vị trí các điểm gãy. Xem ảnh tham chiếu để nhận biết cấu tạo hoặc vật liệu. Chỉ dùng ảnh làm nguồn tỷ lệ khi có kích thước neo cùng mặt phẳng.
2. Phân tích vật thể thành tiết diện, đường dẫn, trục quay, các tiết diện ở nhiều cao độ, các khối cộng/trừ và các chi tiết lặp. Một đối tượng có thể cần phối hợp nhiều phương pháp.
3. Dựng đường chuẩn bằng guide; vẽ và kiểm tra biên kín, đồng phẳng trước khi tạo mặt. Tách vật thể độc lập thành group trước khi chạm vào hình học khác. Dùng component cho cấu kiện lặp, Make Unique cho biến thể.
4. Dựng khối chính trước, rồi khoét mở, thêm chi tiết, làm mềm các cạnh phân đoạn, gán Tag và vật liệu. Giữ các mép gãy thật tại giao mặt cần sắc.
5. Kiểm tra bằng Top, Front và mặt cắt. Đo khổ bao, bề dày, cao độ và độ hở. Kiểm tra mặt trước hướng ra ngoài. Với vật thể cần kín, kiểm tra Solid trong Entity Info; sửa cạnh hở, mặt trùng, mặt trong và giao xuyên trước Boolean hoặc xuất.

Khi người dùng yêu cầu dựng, chọn phương pháp theo hình học và thực thi qua MCP. Với hình học mới, gộp các cấu kiện liên quan vào một lần `draw_geometry`; dùng `build_model` cho tường, sàn và ô mở. Đọc kích thước bao, số mặt và trạng thái Solid sau khi dựng. Chỉ báo hoàn tất phần công cụ đã xác nhận.

## Chọn thao tác MCP

- Tiết diện phẳng đi thẳng: dùng `extrusion` với hướng pháp tuyến và chiều dài có dấu. Khối tròn xoay: dùng `revolve` với trục Z cục bộ và tiết diện bán kính–cao độ. Nón dùng [0,0], [R,0], [0,H]; trụ thêm [R,H] sau [R,0]. Đặt số đoạn theo dung sai, ưu tiên bội số của 4 để các cực nằm đúng trên trục X và Y. Có thể xoay khối khi cần đổi trục.
- Tiết diện chạy theo tuyến: dùng `sweep` với tiết diện đặt vuông góc đúng tại đầu tuyến. Dùng ít đoạn đủ mịn, tránh góc hoặc bán kính gây tự giao. Đặt `solid: true` khi cần kiểm tra kín.
- Tiết diện thay đổi: dùng `loft`, ghép các vòng cùng số đỉnh, cùng chiều và cùng mốc bắt đầu. Dùng một đỉnh ở đầu hoặc cuối cho chóp. Dùng `mesh` cho bề mặt tự do hoặc topology tùy chỉnh, giữ mặt trước hướng ra ngoài và chia tam giác vùng vênh.
- Offset biên ngang đơn bằng `offset`, dấu dương ra ngoài. Nếu biên sụp hoặc tự cắt, giảm khoảng dịch hoặc tính lại các miền; biên nghiêng có thể đổi hệ trục để tính rồi chiếu kết quả về mặt phẳng dựng.
- Dùng `inspect_drawing` để đọc ID, điểm đầu cạnh, biên mặt và nhóm. Dùng `edit_drawing` để sửa vùng chọn, thực hiện biến đổi, tạo bản sao, gán Tag, tô vật liệu, làm mềm cạnh và Boolean các khối Solid. Với tường hiện hữu, ưu tiên `inspect_wall` và `cut_existing_wall`.
- Dùng `measure_drawing` cho khoảng cách và góc, `draw_geometry` cho guide/kích thước/chữ, `set_drawing_axes` khi cần đổi trục vẽ, và `drawing_camera` để kiểm tra nhiều hướng. Điều khiển Walk theo tọa độ là dịch chuyển camera ngang. Dùng viewport để kiểm tra mô hình thay vì suy đoán từ lời mô tả.

Chọn mốc, hướng, độ mịn và vị trí tương đối hợp lý khi yêu cầu đã đủ kích thước. Nếu công cụ báo lỗi hình học, sửa đầu vào hoặc chuyển phương pháp tương đương rồi kiểm tra lại.

## Công cụ và cơ chế

| Công cụ | Thao tác và ứng dụng | Cơ chế hình học / Ruby API |
| --- | --- | --- |
| Select, Lasso | Bấm chọn hoặc quét. Khung trái sang phải lấy đối tượng nằm trọn, phải sang trái lấy đối tượng giao vùng. Lasso hữu ích khi biên chọn lượn theo hình. Kiểm tra cấp chỉnh sửa trước khi thao tác. | Selection, PickHelper và phép chiếu viewport. Chọn group khác với chọn các mặt bên trong. |
| Paint Bucket | Tô mặt hoặc group, lấy mẫu bằng Alt. Kiểm tra mặt trước, UV và hướng vân. | Face#material, #back_material; vật liệu cấp instance có thể bị vật liệu cấp mặt ghi đè. |
| Eraser | Xóa cạnh thừa, Shift ẩn, Ctrl làm mềm/mượt. Cạnh chung vẫn ảnh hưởng topology kể cả khi bị ẩn. | Entities#erase_entities có thể làm mất mặt liền kề. Edge#soft, #smooth và #hidden phục vụ các mục đích khác nhau. |
| Make Component, Tag | Gom cụm lặp thành component, đặt điểm chèn ở mốc lắp ráp. Gán Tag cho group/component, giữ cạnh và mặt rời ở Untagged. | ComponentDefinition chứa hình học chung; ComponentInstance giữ phép biến đổi riêng. Model#layers quản lý Tag. |
| Line, Freehand | Line đặt hai đầu chính xác và khép vòng phẳng. Freehand vẽ chuỗi nét hữu cơ; dùng ít đoạn đủ mượt. | Entities#add_line, #add_curve, #add_face. Vòng kín cần liên tục và không tự cắt; Curve vẫn gồm nhiều Edge. |
| Rectangle, Rotated Rectangle | Rectangle dùng hai góc đối. Rotated Rectangle xác định cạnh đầu, mặt phẳng và bề rộng. | Bốn điểm đồng phẳng ghép bằng add_face; cạnh thứ hai vuông góc cạnh đầu trong mặt phẳng chọn. |
| Circle, Polygon | Chọn mặt phẳng, tâm và bán kính. Polygon xác định số cạnh; phân biệt bán kính ngoại tiếp và nội tiếp. | add_circle / add_ngon tạo tập cạnh. Thêm mặt khi cần đùn; số đoạn ảnh hưởng độ mịn và khả năng bắt điểm. |
| Arc, 2 Point Arc, 3 Point Arc, Pie | Arc lấy tâm, bán kính, góc quét. 2 Point Arc lấy hai đầu rồi độ võng. 3 Point Arc chọn đầu, điểm trên cung và cuối. Pie khép cung tới tâm. | add_arc dùng tâm, pháp tuyến, hướng bán kính đầu, bán kính, góc và số đoạn. Ba điểm không thẳng hàng xác định đường tròn; điểm trung gian chọn cung lớn hay nhỏ. |
| Move | Bắt điểm gốc và điểm đích, khóa hướng; Ctrl tạo bản sao. Sau bản sao đầu, dùng nhân hoặc chia đều để tạo dãy. | Translation. Mảng lặp có thể đặt instance chung definition với transformation riêng. |
| Push/Pull | Đùn mặt theo pháp tuyến với chiều sâu chính xác. Ctrl giữ mặt nguồn khi cần bước đùn mới. | Face#pushpull; dấu khoảng cách theo pháp tuyến. Khoét xuyên bằng mặt ô trên tường khi hình học cùng context và hai mặt song song; dùng Solid Tools khi cắt khối kín. |
| Rotate | Chọn tâm, mặt phẳng, tia gốc và góc. Sao chép xoay để tạo mảng tròn. | Transformation.rotation quanh trục qua pivot; góc Ruby dùng radian. |
| Follow Me | Chọn đường dẫn, gọi công cụ rồi bấm mặt tiết diện. Đặt tiết diện tại đầu đường, vuông góc với đoạn đầu khi cần đúng kích thước. | Face#followme với chuỗi Edge liền nhau trong cùng context. Kiểm tra tự cắt ở bán kính cong nhỏ và góc gấp. |
| Scale | Thay đổi kích thước bằng tay nắm; chọn điểm neo và giữ tỷ lệ theo yêu cầu. | Transformation.scaling. Scale thay tỷ lệ từ tâm neo; không tạo bề dày biên đều như Offset. |
| Offset | Dịch biên trong mặt phẳng theo khoảng cách, hữu ích cho bề dày tường và khung. | API 2024 không có Face#offset. Dịch các đường hỗ trợ theo pháp tuyến trong mặt phẳng, giao đường liên tiếp rồi xử lý góc lõm, lỗ, cạnh sụp và tự giao. |
| Flip | Chọn mặt phẳng phản chiếu đúng vị trí; Ctrl sao chép đối xứng. | Phép phản chiếu theo pháp tuyến của mặt phẳng. Kiểm tra định hướng trái/phải và hướng mặt sau phản chiếu. |
| Tape Measure, Dimensions | Tape Measure đo mốc và dựng guide. Dimensions đặt số đo hiển thị; dùng điểm gắn thật để theo hình học. | Point3d#distance, ConstructionLine/Point, Entities#add_dimension_linear. Nhập lại kích thước sau đo có thể đổi tỷ lệ toàn context. |
| Protractor, Axes | Dựng guide góc từ đỉnh và tia chuẩn. Đặt gốc, trục đỏ, phía xanh lá để thuận tiện vẽ hình xoay. | Vector3d#angle_between, Transformation.rotation, Axes#set. Đổi trục vẽ không dời hình học; dùng chuyển đổi hệ trục khi tính tọa độ. |
| Text, 3D Text | Text chú thích, 3D Text tạo hình chữ có mặt và độ dày. Đặt hướng chữ theo bề mặt lắp. | Entities#add_text và #add_3d_text. Text thường là chú thích; 3D Text tạo hình học trong context. |
| Orbit, Pan, Zoom, Zoom Window, Zoom Extents, Previous View | Quay quan sát, dịch khung, phóng theo vùng, lấy toàn cảnh hoặc trở về góc nhìn trước. Dùng để kiểm tra nhiều phía. | View và Camera. Pan dời eye và target cùng vector; Orbit quay eye quanh mốc; Previous View chỉ đổi trạng thái camera. |
| Position Camera, Walk, Look Around, Field of View | Đặt vị trí và chiều cao mắt, đi qua không gian, xoay nhìn tại chỗ hoặc chỉnh góc nhìn. | Camera có eye/target/up và fov; Walk tương tác còn xử lý điều hướng. Góc rộng có thể làm sai cảm nhận tỷ lệ khi đối chiếu hình. |

Nút Warehouse, chia sẻ hay quản lý ở cuối thanh dùng cho thư viện, tài khoản hoặc tiện ích. Dùng tooltip trên phiên bản đang chạy để nhận diện chính xác.

## Phối hợp theo họ hình khối

| Bài toán | Trình tự dựng | Kiểm tra |
| --- | --- | --- |
| Tường, sàn, bậc thẳng, vật thể có tiết diện đều | Guide → Line/Rectangle/Arc tạo mặt → Offset nếu có vòng rỗng → Push/Pull → Group. | Chiều sâu đùn, bề dày tại các góc, đáy/đỉnh và hướng mặt. |
| Cửa, hốc, lỗ xuyên | Tạo tường kín → đặt kích thước và cao độ ô → Push/Pull tới mặt sau hoặc dùng cutter và Trim → dựng riêng khung/cánh/kính trong ô. | Chiều sâu lỗ, bề dày còn lại, khoảng hở, ô xuyên thật và các vật thể lân cận. |
| Len, phào, lan can, ống cong | Vẽ tuyến bằng Line/Arc → xử lý chỗ nối và bán kính → dựng tiết diện → Follow Me → làm mềm cạnh trung gian. | Tiết diện không xoắn bất ngờ, đoạn nối kín; bán kính tuyến đủ lớn so với tiết diện. |
| Cột tròn, chậu, tay nắm tròn xoay | Vẽ nửa tiết diện dọc từ trục → Circle tâm trên trục làm đường dẫn → Follow Me → kiểm tra vòng nối. | Biên tiết diện không vượt trục, độ mịn, không bị hở tại tâm. |
| Khối vát, tháp thu nhỏ, khối đổi tiết diện | Tạo các vòng tại cao độ cần thiết bằng Move/Rotate/Scale → đặt cùng số đỉnh và cùng thứ tự → nối cặp đỉnh bằng Line → chia tam giác những dải không đồng phẳng → đóng hai đầu. | Đỉnh đối ứng không xoắn chéo, chiều mặt nhất quán, mép nối kín. |
| Mặt tự do, địa hình | Đặt đường kiểm soát hoặc tiết diện theo lớp → lấy mẫu dày hơn nơi cong nhiều → nối thành lưới tam giác → làm mềm cạnh nội bộ. Với đường đồng mức dùng Sandbox From Contours nếu phù hợp. | Chọn mật độ theo dung sai; đo độ lệch tại các tiết diện; tránh tam giác dài mảnh và giao xuyên. |
| Chi tiết lặp hoặc đối xứng | Make Component → Move copy theo hàng → Rotate copy quanh tâm hoặc Flip copy qua mặt phẳng. | Chọn pivot theo trục lắp, phân biệt số bản sao với số khoảng chia; làm riêng biến thể trước khi sửa. |
| Mái dốc | Vẽ mặt ngang theo đỉnh tường, dựng độ đua từ đường bao → xác định các mặt có dốc theo hướng pháp tuyến eave → giao mặt để ra sống, hông và khe → thêm diềm. Luồng mái hông của Nếp Nhà dùng nguyên lý này cho các đường bao được hỗ trợ. | Cao độ gặp tường, chiều dốc theo phương vuông góc mép, liên tục ở giao tuyến và thoát nước tại góc lõm. |

Với hình phức tạp, bắt đầu từ hai hoặc ba tiết diện kiểm soát, dựng một phần nhỏ rồi đo lại trước khi nhân hoặc nối toàn bộ. Tam giác hóa cho phép xấp xỉ bề mặt không đồng phẳng trong mô hình cạnh/mặt của SketchUp; ghi rõ dung sai nếu công việc cần chế tạo hoặc bóc khối lượng.

[Tài liệu Large Tool Set 2024 cho Windows](https://download.sketchup.com/QRC2024/QRC2024-SU-Windows-en.pdf) · [Ruby Entities](https://ruby.sketchup.com/Sketchup/Entities.html) · [Ruby Face](https://ruby.sketchup.com/Sketchup/Face.html) · [Ruby Transformation](https://ruby.sketchup.com/Geom/Transformation.html) · [Ruby Camera](https://ruby.sketchup.com/Sketchup/Camera.html)
