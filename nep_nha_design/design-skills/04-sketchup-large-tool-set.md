# Large Tool Set của SketchUp 2024 trên Windows

## Chọn cách thực hiện

- Khi người dùng yêu cầu tạo hoặc sửa đối tượng và có đủ thông số, gọi MCP. Khi họ hỏi cách dùng, hướng dẫn thao tác trên thanh công cụ và ô Measurements (VCB). Khi họ yêu cầu mở công cụ để tự thao tác, dùng activate_native_tool nếu có khóa được hỗ trợ.
- activate_native_tool dựa trên send_action, được SketchUp đánh dấu deprecated. queued chỉ xác nhận lệnh đã vào hàng đợi, chưa xác nhận công cụ đã hoạt động hay model đã đổi. Nếu không nhận lệnh, chỉ đường dẫn menu hoặc tìm tên công cụ bằng SketchUp Search. Không dùng ID Windows không được hỗ trợ, tự bấm chuột hay chạy Ruby Console.
- Vẽ theo XYZ model, mm ở MCP, inch nội bộ Ruby qua Numeric#mm; góc nhập độ và chuyển sang radian qua Numeric#degrees. Hỏi mốc đặt khi kích thước đủ nhưng vị trí chưa xác định. Với vẽ tay, khóa suy luận bằng Shift hoặc phím mũi tên phù hợp; xem tooltip và trạng thái vì phím tắt có thể tùy chỉnh.
- draw_geometry thêm một group riêng. edit_drawing yêu cầu đúng persistent ID vùng chọn lúc gửi và ở cấp model; thao tác trên model chạy qua một Undo. Push/Pull và Follow Me trực tiếp lên hình rời bằng MCP yêu cầu mặt/cạnh ở cấp model. Với hình trong group, mở group và dùng công cụ tương tác, hoặc dùng build_model cho một khối mới. Tránh kéo dính hình giữa các cấu kiện.
- Khi đọc tọa độ của entity lồng nhau, chuyển từ tọa độ definition qua InstancePath#transformation. Khi vẽ theo hệ trục người dùng đã chỉnh, đổi điểm sang hệ model bằng Axes#transformation nếu cần. Không dùng một PID làm bằng chứng về bề dày, trục hoặc hình dáng.
- Các ví dụ dưới đây là dữ liệu hoặc quy trình tham khảo, không phải yêu cầu chỉnh sửa model đang mở.

## Chọn và tổ chức

| Nút | Cách thao tác | Cơ chế Ruby và cách trợ lý xử lý |
| --- | --- | --- |
| Select | Bấm cạnh, mặt hay group. Khung trái sang phải lấy vật nằm gọn; phải sang trái lấy cả vật cắt qua khung. | Selection#add/remove/clear, PickHelper#do_pick hoặc #window_pick. Trợ lý đọc ảnh chụp vùng chọn lúc gửi và dùng ID; mở select khi cần người dùng chọn. |
| Lasso | Vẽ vùng bao tự do; dùng modifier để cộng, trừ hoặc đảo chọn. | Custom Tool có thể dùng screen_coords cùng kiểm tra đa giác 2D và PickHelper để xét đối tượng. Không có khóa activate_native_tool cho Lasso; dùng Tools > Lasso. |
| Paint Bucket | Chọn vật liệu rồi bấm mặt hoặc group. Alt lấy mẫu; chế độ tô theo vùng hoặc thay hàng loạt cần xác định phạm vi. | Materials và Drawingelement#material=. Face có mặt trước và back_material. edit_drawing paint tô đối tượng đã chọn; upsert_material đổi định nghĩa vật liệu và ảnh hưởng các nơi đang dùng. |
| Eraser | Bấm hoặc rà trên cạnh để xóa. Shift ẩn; Ctrl làm mềm/mượt; Alt bỏ mềm/mượt. | erase_entities có thể làm mất mặt liền kề; hidden, soft và smooth có ý nghĩa riêng. edit_drawing hỗ trợ từng chế độ cho cạnh đã chọn. |
| Make Component | Chọn hình, đặt tên/điểm chèn; bản sao thường chia sẻ definition. | Group#to_component chuyển một group đang chọn. Dùng DefinitionList và Entities#add_instance để tạo các instance lặp; make_unique trước khi muốn sửa riêng. |
| Tag | Chọn Tag rồi bấm đối tượng. Raw geometry nên ở Untagged và gán Tag cho group/component. | Model#layers là tên API lịch sử. ensure_tag tạo hoặc tìm tên, edit_drawing tag gán vào instance. Tag điều khiển hiển thị, group tách hình học. |

## Vẽ đường, mặt và cung

| Nút | Cách thao tác | Cơ chế Ruby và cách trợ lý xử lý |
| --- | --- | --- |
| Line | Chọn hai đầu; khóa hướng rồi gõ chiều dài. Khép một vòng phẳng để được mặt. | Entities#add_line hoặc add_face cho vòng kín có thứ tự. draw_geometry line nhận đúng hai điểm; face nhận các góc đi quanh biên. |
| Freehand | Giữ chuột và vẽ nét liên tục, nhả để có một đường ghép. | Entities#add_curve nhận chuỗi điểm. draw_geometry freehand nhận mẫu đã đơn giản hóa; nên bỏ điểm trùng hoặc đoạn quá ngắn. |
| Rectangle | Bấm hai góc đối; nhập hai kích thước trong Measurements. | Entities#add_face với bốn góc đồng phẳng. draw_geometry rectangle dùng bốn góc đã xác định theo thứ tự. |
| Rotated Rectangle | Bấm hai góc tạo cạnh đầu rồi định hướng mặt phẳng và chiều rộng bằng góc thứ ba. | Dựng cạnh thứ hai vuông góc với cạnh đầu trong mặt phẳng đã chọn, tạo góc thứ tư bằng phép cộng vector. draw_geometry rotated_rectangle nhận cả bốn góc. |
| Circle | Chọn mặt phẳng, tâm và bán kính; nhập số đoạn nếu cần. | Entities#add_circle tạo ArcCurve gồm các cạnh; draw_geometry circle nhận tâm, điểm bán kính, điểm xác định mặt phẳng. filled tạo mặt để Push/Pull. |
| Polygon | Chọn số cạnh, tâm và một đỉnh; phân biệt bán kính tới đỉnh với bán kính nội tiếp. | Entities#add_ngon hoặc quay vector bán kính đều quanh pháp tuyến. draw_geometry polygon giữ hướng của đỉnh đầu đã nhập. |
| Arc | Chọn tâm, điểm đầu và góc quét trong mặt phẳng. | Entities#add_arc nhận tâm, trục hướng điểm đầu, pháp tuyến, bán kính, góc đầu/cuối, số đoạn. draw_geometry arc dùng góc quét dương theo pháp tuyến xác định bởi ba điểm. |
| 2 Point Arc | Chọn hai đầu dây cung rồi đặt độ võng qua một điểm trên cung. Có thể nhập bán kính hoặc số đoạn. | Từ hai đầu và điểm độ võng suy ra đường tròn qua ba điểm. draw_geometry two_point_arc nhận theo thứ tự đầu, điểm trên cung, cuối; tránh ba điểm thẳng hàng. |
| 3 Point Arc | Chọn lần lượt đầu, điểm trung gian trên cung và cuối. | draw_geometry three_point_arc tìm tâm ngoại tiếp và hướng quét đi qua điểm trung gian, kể cả cung lớn hơn 180 độ. |
| Pie | Dùng tâm, điểm bán kính và góc như Arc; kết quả kín tới tâm. | draw_geometry pie thêm hai bán kính vào cung rồi add_face. Góc quét phải nằm giữa 0 và 360 độ. |

## Chỉnh sửa hình học

| Nút | Cách thao tác | Cơ chế Ruby và cách trợ lý xử lý |
| --- | --- | --- |
| Move | Chọn vật, bắt mốc gốc, khóa hướng và nhập độ dời. Ctrl chuyển chế độ sao chép, dùng mảng khi cần. | Geom::Transformation.translation rồi Entities#transform_entities. edit_selection move_mm dịch đúng group/component đã chọn. Sao chép/mảng tương tác dùng Move. |
| Push/Pull | Chọn mặt, kéo theo pháp tuyến, nhập số đo. Ctrl giữ lại mặt nguồn trong chế độ sao chép. | Face#pushpull(dist, copy) trong edit_drawing. Dấu khoảng cách theo pháp tuyến. Dùng build_model để đùn nhiều khối từ mặt bằng và khoét tường bằng solid cutter đã có. |
| Rotate | Đặt mặt phẳng thước, tâm, tia gốc và góc. | Geom::Transformation.rotation dùng pivot, trục và góc. edit_drawing rotate xoay vùng chọn; dùng Rotate tương tác để sao chép. |
| Follow Me | Chọn đường dẫn liền mạch rồi bấm mặt tiết diện đặt tại đầu đường; tiết diện nên vuông góc với tiếp tuyến đầu. | Face#followme trên dãy Edge đúng thứ tự trong cùng context. edit_drawing follow_me nhận một mặt và path_ids của tất cả cạnh đã chọn. Dùng làm chỉ, len hoặc ống; kiểm tra tự giao ở các góc gấp. |
| Scale | Kéo tay nắm trục hoặc góc; khóa đồng tỷ lệ khi cần. | Geom::Transformation.scaling theo pivot và ba hệ số. edit_drawing scale dùng hệ trục model; dùng Scale gốc khi cần tay nắm theo trục cục bộ. |
| Offset | Chọn mặt/vòng cạnh, kéo về trong hoặc ngoài rồi nhập khoảng cách. | API 2024 không có Face#offset. Có thể dịch từng đường cạnh trong mặt phẳng, giao các đường song song bằng Geom.intersect_line_line, xử lý góc lõm, các vòng lỗ và tự giao. Với đường bao tổng quát, mở offset để người dùng nhập khoảng cách; không thay bằng Scale. |
| Flip | Chọn vật, chọn mặt phẳng phản chiếu; Ctrl tạo bản sao đối xứng. | edit_drawing flip lấy pivot và pháp tuyến X/Y/Z hệ model, dùng hệ số âm theo trục đó. Dùng Flip gốc khi muốn chọn mặt phẳng theo trục cục bộ hoặc sao chép. |

## Đo, chú thích và trục

| Nút | Cách thao tác | Cơ chế Ruby và cách trợ lý xử lý |
| --- | --- | --- |
| Tape Measure | Bắt hai mốc để đo. Khi tạo guide, bắt trên cạnh rồi kéo song song hoặc bắt điểm để định khoảng. | measure_drawing nhận hai điểm; draw_geometry guide_line/guide_point dùng ConstructionLine/Point. Đổi tỷ lệ toàn model là thao tác riêng của Tape Measure, chỉ làm khi được yêu cầu. |
| Dimensions | Bắt hai đầu cạnh rồi đặt đường kích thước cách vật. | Entities#add_dimension_linear. draw_geometry dimension nhận hai điểm tĩnh và vector offset. Muốn kích thước cập nhật theo entity dùng overload tham chiếu entity/InstancePath. |
| Protractor | Chọn mặt phẳng, đỉnh, tia chuẩn rồi góc; có thể đặt guide. | Vector3d#angle_between ở measure_drawing. draw_geometry angle_guide quay tia bằng Transformation.rotation rồi tạo đường chuẩn. |
| Text | Đặt chú thích vào điểm hoặc lên đối tượng. | Entities#add_text tạo nhãn, có overload gắn đường dẫn/tham chiếu. draw_geometry text dùng điểm tĩnh. |
| Axes | Bấm gốc, hướng đỏ và phía xanh lá; trục xanh dương xác định theo quy tắc bàn tay phải. | Model#axes và Axes#set. set_drawing_axes dựng bộ trục vuông góc từ ba điểm. Đổi trục thao tác, hình học giữ vị trí. |
| 3D Text | Nhập chữ, font, chiều cao; chọn tạo mặt và độ đùn, rồi đặt chữ. | Entities#add_3d_text tạo cạnh/mặt; draw_geometry text_3d sinh chữ Arial trong group, cao và sâu theo mm, mặt phẳng XY. |

## Camera

| Nút | Cách thao tác và cơ chế |
| --- | --- |
| Orbit | Quay góc nhìn quanh đối tượng bằng kéo chuột hoặc nút giữa. activate_native_tool orbit. Với góc xác định, drawing_camera position đặt eye và target. |
| Pan | Dịch ngang/dọc ảnh bằng Pan hoặc Shift + nút giữa. Với dịch chuyển định lượng, dời eye và target cùng vector trong mặt phẳng camera. Dùng nút Pan cho thao tác kéo. |
| Zoom | Cuộn hoặc kéo. drawing_camera zoom dùng View#zoom với hệ số từ 1 đến 10; mở zoom để kéo tùy ý. |
| Zoom Window | Kéo khung vùng cần phóng; activate_native_tool zoom_window. View#zoom(selection) dùng khi mục tiêu là hình học đã chọn. |
| Zoom Extents | drawing_camera extents gọi View#zoom_extents để vừa model; selection chỉ vừa vùng chọn. |
| Previous View | Quay lại góc nhìn trước, không Undo hình học; activate_native_tool previous_view. |
| Position Camera | Lấy điểm đặt và chiều cao mắt, chỉ hướng nhìn. drawing_camera position nhận eye, target, up và FOV tùy chọn. |
| Walk | Di chuyển qua model với điều khiển người đi bộ; activate_native_tool walk. Camera#set đơn lẻ không mô phỏng va chạm. |
| Look Around | Giữ vị trí mắt và đổi hướng nhìn; activate_native_tool look_around hoặc đặt lại target với eye cũ qua drawing_camera position. |
| Field of View | Đổi độ rộng góc nhìn ở chế độ phối cảnh; activate_native_tool field_of_view hoặc đặt fov_deg khi tạo camera với cùng eye và target. |

## Nút thư viện, chia sẻ và quản lý

- 3D Warehouse tìm và tải model; Extension Warehouse tìm tiện ích; Extension Manager quản lý RBZ. Các hộp thoại, đăng nhập và cài đặt thuộc giao diện SketchUp. Khi người dùng đã có .skp, API Definitions#load và Entities#add_instance có thể nhập và đặt model trong luồng tích hợp riêng.
- Với cụm biểu tượng chồng lớp ở cuối ảnh, dùng tooltip hoặc View > Toolbars để xác nhận tên của bản cài. Đối chiếu nhóm Warehouse/Trimble Connect nếu có các lệnh chia sẻ model, mở/lưu từ đám mây hoặc quản lý tiện ích. Đây là thao tác tài khoản/tệp; hướng dẫn người dùng thực hiện từ nút hoặc menu tương ứng.
- Nguồn: [Quick Reference Card 2024 Windows](https://download.sketchup.com/QRC2024/QRC2024-SU-Windows-en.pdf), [SketchUp Toolbars](https://help.sketchup.com/en/sketchup/toolbars), [Drawing Arcs](https://help.sketchup.com/en/sketchup/drawing-arcs), [Ruby Entities](https://ruby.sketchup.com/Sketchup/Entities.html), [Ruby Face](https://ruby.sketchup.com/Sketchup/Face.html), [Ruby Selection](https://ruby.sketchup.com/Sketchup/Selection.html), [Ruby Axes](https://ruby.sketchup.com/Sketchup/Axes.html), [Ruby View](https://ruby.sketchup.com/Sketchup/View.html), [Ruby Camera](https://ruby.sketchup.com/Sketchup/Camera.html), [Ruby send_action](https://ruby.sketchup.com/Sketchup.html#send_action-class_method).
