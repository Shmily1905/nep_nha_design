# frozen_string_literal: true

require 'sketchup.rb'
require 'socket'
require 'json'
require 'base64'
require 'tmpdir'
require 'digest'
require_relative 'build_model'
require_relative 'drawing_tools'

module NepNhaDesign
  module Bridge
    HOST = '127.0.0.1'
    PORT = 9876
    VERSION = '1.15.0'
    MAX_REQUEST = 512 * 1024
    MAX_IMAGE = 4 * 1024 * 1024
    MAX_CLIENTS = 8
    CHUNK = 64 * 1024
    IDLE_SECONDS = 10
    Client = Struct.new(:socket, :input, :output, :offset, :deadline)
    class RPCError < StandardError
      attr_reader :code

      def initialize(code, message)
        super(message)
        @code = code
      end
    end

    class << self

      def start
        return true if @listener

        @clients = []
        @listener = TCPServer.new(HOST, PORT)
        @timer = UI.start_timer(0.05, true) { tick }
        puts "[Nếp Nhà Design] Listening on #{HOST}:#{PORT}"
        true
      rescue StandardError => e
        stop
        warn "[Nếp Nhà Design] Start failed: #{e.message}"
        false
      end

      def stop
        UI.stop_timer(@timer) if @timer
        @timer = nil
        (@clients || []).dup.each { |client| close_client(client) }
        close_socket(@listener) if @listener
        @listener = nil
        nil
      end

      def pin_model(token, model, frame)
        (@model_pins ||= {})[token] = { model: model, frame: frame, roots: [], materials: [] }
      end

      def release_model_pin(token)
        @model_pins&.delete(token)
      end

      def start_image_stage(token, stage)
        state = @model_pins.fetch(token)
        state.merge!(stage: stage, stage_roots: [], image: nil, cut: false, painted: false)
      end

      def image_stage_capture(token)
        state = @model_pins.fetch(token)
        model = state.fetch(:model)
        return nil unless Sketchup.active_model == model && !model.active_path
        return nil if state[:stage] == 0 && state[:roots].empty?
        return nil if state[:stage] == 3 && !state[:painted]

        state[:image]
      end

      def image_stage_built?(token)
        state = @model_pins.fetch(token)
        state[:cut] || state[:painted] || !state[:stage_roots].empty?
      end

      private

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def close_socket(socket)
        socket.close
      rescue IOError, SystemCallError
        nil
      end

      def close_client(client)
        @clients.delete(client)
        close_socket(client.socket)
      end

      def tick
        return if @in_tick

        @in_tick = true
        begin
          # At most one SketchUp API request per tick, with round-robin polling.
          dispatched = false
          @clients.length.times do
            client = @clients.shift
            @clients << client
            if now >= client.deadline
              close_client(client)
            elsif client.output
              write_reply(client)
            elsif !dispatched
              dispatched = read_request(client)
            end
          end

          if @clients.length < MAX_CLIENTS
            socket = @listener.accept_nonblock(exception: false)
            unless socket == :wait_readable
              @clients << Client.new(socket, ''.b, nil, 0, now + IDLE_SECONDS)
            end
          end
        rescue IOError, SystemCallError => e
          warn "[Nếp Nhà Design] Socket listener: #{e.message}"
          stop
        rescue StandardError => e
          warn "[Nếp Nhà Design] Timer: #{e.class}: #{e.message}"
        ensure
          @in_tick = false
        end
      end

      def read_request(client)
        data = client.socket.read_nonblock(MAX_REQUEST + 1, exception: false)
        return false if data == :wait_readable
        if data.nil?
          close_client(client)
          return false
        end

        client.input << data
        newline = client.input.index("\n")
        if (newline || client.input.bytesize) > MAX_REQUEST
          client.output = error_reply(nil, -32600, 'Request exceeds frame limit')
        elsif newline
          client.output = handle_request(client.input.byteslice(0, newline))
          close_client(client) unless client.output
        else
          return false
        end
        client.deadline = now + IDLE_SECONDS
        true
      rescue IOError, SystemCallError
        close_client(client)
        false
      end

      def write_reply(client)
        part = client.output.byteslice(client.offset, CHUNK)
        sent = client.socket.write_nonblock(part, exception: false)
        return if sent == :wait_writable

        client.offset += sent
        close_client(client) if client.offset == client.output.bytesize
      rescue IOError, SystemCallError
        close_client(client)
      end

      def error_reply(id, code, message)
        JSON.generate(jsonrpc: '2.0', id: id, error: { code: code, message: message }) + "\n"
      end

      def handle_request(frame)
        id = nil
        notification = false
        request = JSON.parse(frame.force_encoding(Encoding::UTF_8))
        unless request.is_a?(Hash) && request['jsonrpc'] == '2.0' &&
               request['method'].is_a?(String)
          return error_reply(nil, -32600, 'Invalid JSON-RPC request')
        end

        id = request['id']
        unless id.nil? || id.is_a?(String) || id.is_a?(Numeric)
          return error_reply(nil, -32600, 'Invalid JSON-RPC id')
        end
        notification = !request.key?('id')
        # This bridge accepts calls with an id. Notifications have no side effects.
        return nil if notification

        params = request.fetch('params', {})
        raise RPCError.new(-32602, 'Expected named parameters') unless params.is_a?(Hash)

        stage = nil
        if request.key?('model_guard')
          stage = @model_pins&.fetch(request['model_guard'], nil)
          expected = stage&.fetch(:model)
          unless expected && Sketchup.active_model == expected && !expected.active_path
            raise RPCError.new(-32001, 'Model hoặc vùng chỉnh sửa đã đổi. Hãy gửi lại yêu cầu ở model đích.')
          end
        end
        result = stage ? dispatch_image_stage(stage, request['method'], params) : dispatch(request['method'], params)
        JSON.generate(jsonrpc: '2.0', id: id, result: result) + "\n"
      rescue JSON::ParserError
        error_reply(nil, -32700, 'Invalid JSON')
      rescue RPCError => e
        error_reply(id, e.code, e.message)
      rescue StandardError => e
        warn "[Nếp Nhà Design] RPC: #{e.class}: #{e.message}"
        error_reply(id, -32603, 'SketchUp API error. See Ruby Console.')
      end

      def dispatch_image_stage(state, method, params)
        model = state.fetch(:model)
        index = state.fetch(:stage)
        case method
        when 'capture_viewport'
          camera = state[:camera]
          raise RPCError.new(-32602, 'Đặt máy theo ảnh bằng drawing_camera action=position trước khi chụp.') unless camera

          eye, target, up, perspective, optics = camera
          locked = Sketchup::Camera.new(eye, target, up, perspective)
          if perspective
            locked.fov = optics
          else
            locked.height = optics
          end
          model.active_view.camera = locked
          width, height = state.fetch(:frame)
          picture = capture_viewport(model, { 'width' => width, 'height' => height })
          state[:image] = { mime_type: picture[:mime_type], data: picture[:image_base64] }
          return picture
        when 'drawing_camera'
          unless index.zero? && params['action'] == 'position'
            raise RPCError.new(-32602, 'Chỉ đặt máy ở lớp khối thô. Các lớp sau dùng máy đã khóa.')
          end
          result = drawing_camera(model, params)
          view = model.active_view.camera
          perspective = view.perspective?
          state[:camera] = [view.eye, view.target, view.up, perspective, perspective ? view.fov : view.height]
        when 'draw_geometry', 'build_hip_roof'
          unless (method == 'draw_geometry' && index < 3) || (method == 'build_hip_roof' && index == 2)
            raise RPCError.new(-32602, 'Công cụ dựng này nằm ngoài lớp hiện tại.')
          end
          items = params.fetch('items', [])
          if items.any? { |item| item['material'] && !state[:materials].include?(item['material']) }
            raise RPCError.new(-32602, 'Chỉ dùng vật liệu được tạo trong lượt dựng này.')
          end
          result = dispatch(method, params)
          if result[:created]
            state[:roots] << result.fetch(:group_id)
            state[:stage_roots] << result.fetch(:group_id)
          elsif !state[:roots].include?(result[:group_id])
            raise RPCError.new(-32602, 'ID dựng đã được sử dụng trong model. Hãy chọn ID mới.')
          end
        when 'cut_existing_wall'
          raise RPCError.new(-32602, 'Chỉ khoét ô ở lớp 2.') unless index == 1

          wall = image_stage_group(state, params['wall_id'])
          raise RPCError.new(-32602, 'Tường cần khoét phải là một Solid kín.') unless wall.manifold?

          result = cut_wall_in_context(model, params, wall, wall.parent.entities)
          state[:cut] = true
        when 'upsert_material'
          unless [1, 3].include?(index) &&
                 (state[:materials].include?(params['name']) || !model.materials[params['name'].to_s])
            raise RPCError.new(-32602, 'Chỉ tạo hoặc sửa vật liệu riêng của lượt dựng ở lớp mở ô và tô màu.')
          end
          result = upsert_material(model, params)
          state[:materials] |= [result.fetch(:name)]
        when 'edit_drawing'
          ids = params['ids']
          raise RPCError.new(-32602, 'Cần ID cấu kiện.') unless ids.is_a?(Array) && !ids.empty?

          groups = ids.uniq.map { |id| image_stage_group(state, id) }
          case params['action']
          when 'paint'
            material = model.materials[params['material'].to_s] if state[:materials].include?(params['material'])
            raise RPCError.new(-32602, 'Tạo vật liệu riêng rồi tô màu ở lớp 4.') unless index == 3 && material

            with_operation(model) do
              groups.each { |group| group.material = material }
            end
            state[:painted] = true
          when 'erase'
            unless index < 3 && (ids - state[:stage_roots]).empty?
              raise RPCError.new(-32602, 'Chỉ thay khối do chính lớp đang dựng tạo ra.')
            end
            with_operation(model) { model.entities.erase_entities(groups) }
            state[:roots] -= ids
            state[:stage_roots] -= ids
          else
            raise RPCError.new(-32602, 'Để sửa khối sai, dựng bản đúng rồi bỏ nhóm sai của lớp này.')
          end
          result = { affected: groups.length }
        when 'ping_sketchup', 'get_model_info', 'inspect_drawing', 'measure_drawing'
          return dispatch(method, params)
        else
          raise RPCError.new(-32602, 'Công cụ này không nằm trong quy trình dựng theo ảnh đã duyệt.')
        end
        state[:image] = nil
        result
      end

      def image_stage_group(state, id)
        model = state.fetch(:model)
        group = model.find_entity_by_persistent_id(id) if id.is_a?(Integer)
        if group.is_a?(Sketchup::Group) && !group.locked?
          root = group
          until root.parent == model
            parent = root.parent
            if parent.is_a?(Sketchup::Group)
              root = parent
            elsif parent.is_a?(Sketchup::ComponentDefinition) && parent.instances.length == 1
              root = parent.instances.first
            else
              break
            end
            break if root.locked?
          end
          return group if !root.locked? && root.parent == model && state[:roots].include?(root.persistent_id)
        end
        raise RPCError.new(-32602, 'Chọn ID nhóm thuộc lượt dựng ảnh này.')
      end

      def dispatch(method, params)
        case method
        when 'ping_sketchup'
          { status: 'ok', product: 'nep-nha-design', bridge_version: VERSION, sketchup_version: Sketchup.version,
            ruby_version: RUBY_VERSION, units: 'mm' }
        when 'get_model_info'
          model_info(active_model)
        when 'clear_scene'
          clear_scene(active_model, params)
        when 'capture_viewport'
          capture_viewport(active_model, params)
        when 'ensure_tag'
          ensure_tag(active_model, params)
        when 'upsert_material'
          upsert_material(active_model, params)
        when 'draw_geometry'
          draw_geometry(active_model, params)
        when 'build_hip_roof'
          build_hip_roof(active_model, params)
        when 'inspect_drawing'
          inspect_drawing(active_model, params)
        when 'select_drawing'
          select_drawing(active_model, params)
        when 'edit_drawing'
          edit_drawing(active_model, params)
        when 'measure_drawing'
          measure_drawing(params)
        when 'set_drawing_axes'
          set_drawing_axes(active_model, params)
        when 'drawing_camera'
          drawing_camera(active_model, params)
        when 'build_model'
          build_model(active_model, params.reject { |key, _| %w[fit_openings hip_roof].include?(key) })
        when 'prepare_hip_roof_face'
          prepare_hip_roof_face(active_model, params)
        when 'inspect_wall'
          inspect_wall(active_model, params)
        when 'cut_existing_wall'
          cut_existing_wall(active_model, params)
        when 'edit_selection'
          edit_selection(active_model, params)
        else
          raise RPCError.new(-32601, 'Unknown method')
        end
      end

      def active_model
        model = Sketchup.active_model
        raise RPCError.new(-32001, 'Open a SketchUp model first') unless model

        model
      end

      def selection_info(model)
        return [] unless model

        model.selection.to_a.first(100).map do |entity|
          {
            id: entity.persistent_id, type: entity.typename,
            name: entity.respond_to?(:name) ? entity.name : nil
          }
        end
      end
      public :selection_info, :build_model

      def edit_selection(model, params)
        entities = model.selection.to_a
        ids = params['ids']
        action = params['action']
        value = params['value']
        unless ids.is_a?(Array) && !ids.empty? && ids.length <= 100 &&
               ids.all? { |id| id.is_a?(Integer) } &&
               entities.map(&:persistent_id).sort == ids.sort
          raise RPCError.new(-32602, 'Selection changed. Select the objects and send the prompt again.')
        end
        if action == 'hide_edges'
          unless entities.all? { |entity| entity.is_a?(Sketchup::Edge) }
            raise RPCError.new(-32602, 'Select only the specific edges to hide.')
          end
        else
          unless entities.all? { |entity| (entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)) && !entity.locked? }
            raise RPCError.new(-32602, 'Select unlocked groups or components.')
          end
        end
        with_operation(model) do
          case action
          when 'hide_edges'
            entities.each { |edge| edge.hidden = true }
          when 'rename'
            unless value.is_a?(String) && value.strip.length.between?(1, 100)
              raise RPCError.new(-32602, 'Invalid name.')
            end
            entities.each { |entity| entity.name = value.strip }
          when 'material'
            material = value.is_a?(String) && model.materials[value]
            raise RPCError.new(-32602, 'Material does not exist in this model.') unless material

            entities.each { |entity| entity.material = material }
          when 'move_mm'
            unless value.is_a?(Array) && value.length == 3 &&
                   value.all? { |number| number.is_a?(Numeric) && number.between?(-100_000, 100_000) }
              raise RPCError.new(-32602, 'Provide XYZ offsets in millimeters.')
            end
            transform = Geom::Transformation.translation(value.map(&:mm))
            model.active_entities.transform_entities(transform, entities)
          else
            raise RPCError.new(-32602, 'Unknown edit action.')
          end
          { edited_ids: ids, action: action }
        end
      end

      def point_mm(point)
        [point.x.to_mm, point.y.to_mm, point.z.to_mm]
      end

      def model_info(model)
        bounds = model.bounds
        {
          title: model.title,
          units: 'mm',
          root_entity_count: model.entities.length,
          in_edit_context: !model.active_path.nil?,
          tag_count: model.layers.length,
          material_count: model.materials.length,
          bounds_mm: bounds.valid? ? { min: point_mm(bounds.min), max: point_mm(bounds.max) } : nil
        }
      end

      def with_operation(model)
        unless model.start_operation('AI Build', true)
          raise RPCError.new(-32002, 'Could not start a SketchUp operation')
        end

        begin
          result = yield
          unless model.commit_operation
            raise RPCError.new(-32002, 'Could not commit the SketchUp operation')
          end

          result
        rescue StandardError
          begin
            model.abort_operation
          rescue StandardError => e
            warn "[Nếp Nhà Design] Rollback failed: #{e.message}"
          end
          raise
        end
      end

      def clear_scene(model, params)
        unless params['confirm'] == true
          raise RPCError.new(-32602, 'clear_scene requires confirm: true')
        end
        if model.active_path
          raise RPCError.new(-32002, 'Exit group/component editing before clearing the model')
        end

        count = model.entities.length
        return { removed_root_entities: 0 } if count.zero?

        if model.entities.any? { |entity| entity.respond_to?(:locked?) && entity.locked? }
          raise RPCError.new(-32002, 'Unlock root entities before clearing the model')
        end

        with_operation(model) do
          model.entities.clear!
          unless model.entities.length.zero?
            raise RPCError.new(-32002, 'SketchUp did not clear all root entities')
          end

          { removed_root_entities: count }
        end
      end

      def name_param(params)
        name = params['name']
        unless name.is_a?(String) && name.length.between?(1, 100) &&
               name == name.strip && !name.match?(/[[:cntrl:]]/)
          raise RPCError.new(-32602, 'Expected a name of 1–100 characters without outer whitespace')
        end

        name
      end

      def ensure_tag(model, params)
        name = name_param(params)
        tag = model.layers[name]
        return { name: tag.name, created: false } if tag

        with_operation(model) do
          tag = model.layers.add(name)
          { name: tag.name, created: true }
        end
      end

      def upsert_material(model, params)
        name = name_param(params)
        hex = params['hex_color']
        opacity = params.fetch('opacity', 1.0)
        unless hex.is_a?(String) && hex.match?(/\A#[0-9A-Fa-f]{6}\z/) &&
               opacity.is_a?(Numeric) && opacity.between?(0.0, 1.0)
          raise RPCError.new(-32602, 'Expected #RRGGBB and opacity in [0, 1]')
        end

        rgb = hex.delete_prefix('#').scan(/../).map { |part| part.to_i(16) }
        material = model.materials[name]
        created = material.nil?
        with_operation(model) do
          material ||= model.materials.add(name)
          material.color = Sketchup::Color.new(*rgb)
          material.alpha = opacity.to_f
          { name: material.name, created: created, hex_color: hex.upcase, opacity: material.alpha }
        end
      end

      def capture_viewport(model, params)
        width = params.fetch('width', 960)
        height = params.fetch('height', 540)
        unless [width, height].all? { |size| size.is_a?(Integer) && size.between?(64, 1600) }
          raise RPCError.new(-32602, 'Image width and height must be integers in [64, 1600]')
        end

        Dir.mktmpdir('su-mcp-', Sketchup.temp_dir) do |directory|
          path = File.join(directory, 'viewport.jpg')
          ok = model.active_view.write_image(
            filename: path, width: width, height: height, antialias: true, compression: 0.85
          )
          unless ok && File.file?(path) && File.size(path).between?(1, MAX_IMAGE)
            raise RPCError.new(-32003, 'Viewport export failed or exceeded the image limit')
          end

          { mime_type: 'image/jpeg', image_base64: Base64.strict_encode64(File.binread(path)) }
        end
      end
    end
  end
end

