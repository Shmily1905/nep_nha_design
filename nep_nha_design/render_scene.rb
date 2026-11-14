# frozen_string_literal: true

module NepNhaDesign
  module Setup
    RENDER_RATIOS = {
      '16:9' => [1920, 1080], '4:3' => [1600, 1200], '3:2' => [1800, 1200],
      '1:1' => [1440, 1440], '4:5' => [1280, 1600], '9:16' => [1080, 1920]
    }.freeze
    RENDER_COLORS = [
      [70, 130, 220, 'xanh dương'], [230, 105, 85, 'đỏ gạch'],
      [80, 170, 105, 'xanh lá'], [235, 185, 55, 'vàng'],
      [150, 105, 205, 'tím'], [65, 190, 205, 'xanh lơ'],
      [232, 145, 65, 'cam'], [218, 120, 166, 'hồng'],
      [135, 100, 72, 'nâu'], [150, 155, 166, 'xám']
    ].freeze

    class RenderModelObserver < Sketchup::ModelObserver
      def onTransactionCommit(_model)
        Setup.invalidate_render
      end

      alias onTransactionUndo onTransactionCommit
      alias onTransactionRedo onTransactionCommit
    end

    class << self
      def invalidate_render
        @render_revision = (@render_revision || 0) + 1
      end

      def bind_render_model(model)
        return if model == @render_observed_model

        @render_observed_model&.remove_observer(@render_observer)
        @render_observed_model = model
        @render_observer ||= RenderModelObserver.new
        model&.add_observer(@render_observer)
      end

      def render_watch(enabled)
        if enabled
          return if @render_timer

          preview_render_scene(true)
          @render_timer = UI.start_timer(0.8, true) { preview_render_scene }
        else
          UI.stop_timer(@render_timer) if @render_timer
          @render_timer = nil
          bind_render_model(nil)
        end
      end

      def render_scenes(model)
        model.pages.map { |page| [page.persistent_id.to_s, page.name] }
      end

      def select_render_scene(id)
        model = Sketchup.active_model
        page = model.pages.find { |item| item.persistent_id.to_s == id }
        raise 'Scene không còn trong model.' unless page

        model.pages.selected_page = page
        @render_selected = id
        @render_signature = nil
      rescue StandardError => e
        send_render_state(error: e.message)
      end

      def preview_render_scene(force = false)
        return if @render_source&.fetch(:uploaded, false)
        return if @chat_busy || @render_processing

        model = Sketchup.active_model
        bind_render_model(model)
        view = model.active_view
        camera = view.camera
        scenes = render_scenes(model)
        page = model.pages.selected_page
        signature = [model, scenes, page&.persistent_id, view.vpwidth, view.vpheight,
                     camera.eye.to_a, camera.target.to_a, camera.up.to_a, camera.perspective?,
                     camera.perspective? ? camera.fov : camera.height, camera.aspect_ratio,
                     @render_revision, model.active_path&.map(&:persistent_id)]
        return if !force && signature == @render_signature

        @render_signature = signature
        begin
          aspect = camera.aspect_ratio
          aspect = view.vpwidth.to_f / view.vpheight unless aspect.positive?
          width = (1920 * [aspect, 1].min).round.clamp(1, 1920)
          height = (1920 / [aspect, 1].max).round.clamp(1, 1920)
          filename = File.join(@render_dir, 'scene.png')
          legend = capture_material_ids(model, filename, width, height)
          @render_source = { filename: filename, legend: legend, model: model }
          @render_signature = signature
          send_render_state(scenes: scenes, scene: page&.name, selected: render_selected(page), src: render_image_data(filename))
        rescue StandardError => e
          @render_source = nil
          send_render_state(scenes: scenes, scene: page&.name, error: e.message)
        end
      end

      def render_selected(page)
        @render_selected = nil unless page&.persistent_id.to_s == @render_selected
        @render_selected
      end

      def pick_render_image
        return if @chat_busy || @render_processing

        filename = UI.openpanel('Chọn ảnh khối thô', '', 'Ảnh|*.png;*.jpg;*.jpeg;*.webp||')
        return unless filename

        src = render_image_data(filename)
        @render_selected = nil
        @render_source = { filename: filename, legend: '', uploaded: true }
        send_render_state(src: src, uploaded: File.basename(filename))
      rescue StandardError => e
        send_render_state(error: e.message, keep: true)
      end

      def render_image_data(filename)
        mime = { '.png' => 'png', '.jpg' => 'jpeg', '.jpeg' => 'jpeg', '.webp' => 'webp' }
          .fetch(File.extname(filename).downcase)
        bytes = File.binread(filename, 10 * 1024 * 1024 + 1)
        raise 'Ảnh khối thô tối đa 10 MB.' if bytes.bytesize > 10 * 1024 * 1024

        "data:image/#{mime};base64,#{Base64.strict_encode64(bytes)}"
      end

      def send_render_state(**result)
        @chat_dialog.execute_script("window.NepNhaChat.renderState(#{JSON.generate(result)})")
      end

      def render_crop_request(ratio)
        dimensions = RENDER_RATIOS.fetch(ratio)
        if @render_source && !@render_source[:uploaded] && @render_source[:model] != Sketchup.active_model
          @render_source = nil
        end
        raise 'Chưa có ảnh khối thô. Hãy chọn scene hoặc tải ảnh.' unless @render_source

        { source: @render_source.fetch(:filename), dimensions: dimensions }
      end

      def export_render(ratio)
        return if @chat_busy || @render_processing

        crop = render_crop_request(ratio)
        filename = UI.savepanel('Lưu ảnh khối thô đã cắt', '', "nep-nha-#{ratio.tr(':', 'x')}.png")
        return unless filename

        filename += '.png' unless File.extname(filename).casecmp?('.png')
        @render_processing = true
        @chat_dialog.execute_script('window.NepNhaChat.renderExportStarted()')
        run_panel_task('renderExport', { action: 'render_export', render_crop: crop, destination: filename, ratio: ratio })
      rescue StandardError => e
        @render_processing = false
        @chat_dialog.execute_script("window.NepNhaChat.renderExport(#{JSON.generate(error: e.message)})")
      end

      def capture_material_ids(model, filename, width, height)
        raise ArgumentError, 'Hãy thoát chế độ chỉnh sửa group trước khi xuất ảnh.' if model.active_path

        view = model.active_view
        options = model.rendering_options
        settings = {
          'RenderMode' => 2, 'DisplayColorByLayer' => false, 'ModelTransparency' => false,
          'DisplaySketchAxes' => false, 'DisplayDims' => false, 'DisplayText' => false
        }
        saved = settings.keys.to_h { |key| [key, options[key]] }
        %w[FaceFrontColor FaceBackColor].each { |key| saved[key] = options[key] }
        raise 'Không thể bắt đầu xuất ảnh.' unless model.start_operation('Xuất Material ID', true)

        begin
          palette = {}
          visited = {}
          paint_render_entities(model, model.entities, palette, visited)
          raise 'Scene chưa có bề mặt để xuất ảnh.' unless visited[:faces]

          settings.each { |key, value| options[key] = value }
          default = render_material(model, nil, palette)
          options['FaceFrontColor'] = default.color
          options['FaceBackColor'] = default.color
          view.refresh
          unless view.write_image(filename: filename, width: width, height: height, antialias: true)
            raise 'SketchUp không ghi được ảnh PNG.'
          end
          palette.values.map(&:last).join("\n")
        ensure
          begin
            model.abort_operation
          ensure
            saved.each { |key, value| options[key] = value if options[key] != value }
            view.refresh
          end
        end
      end

      def paint_render_entities(model, entities, palette, visited)
        entities.each do |entity|
          case entity
          when Sketchup::Face
            visited[:faces] = true
            if entity.material || entity.back_material
              entity.material = render_material(model, entity.material, palette) if entity.material
              entity.back_material = render_material(model, entity.back_material, palette) if entity.back_material
            end
          when Sketchup::Group, Sketchup::ComponentInstance
            entity.material = render_material(model, entity.material, palette) if entity.material
            definition = entity.definition
            next if visited[definition]

            visited[definition] = true
            paint_render_entities(model, definition.entities, palette, visited)
          end
        end
      end

      def render_material(model, original, palette)
        return palette[original].first if palette.key?(original)

        index = palette.length
        red, green, blue, color_name = RENDER_COLORS[index % RENDER_COLORS.length]
        if index >= RENDER_COLORS.length
          # Spread additional IDs across the RGB cube, avoiding the common colors.
          red, green, blue = [0, 8, 16].map { |shift| ((index * 0x9E3779) >> shift) & 255 }
          color_name = 'mã màu'
        end
        hex = format('#%02X%02X%02X', red, green, blue)
        name = original ? original.display_name : 'Mặc định'
        material = model.materials.add("Nếp Nhà ID #{hex}")
        material.color = Sketchup::Color.new(red, green, blue)
        palette[original] = [material, "#{color_name} #{hex} → #{name}"]
        material
      end
    end
  end
end
