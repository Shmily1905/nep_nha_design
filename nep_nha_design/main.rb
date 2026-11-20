# frozen_string_literal: true

require 'cgi'
require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'thread'
require 'timeout'
require 'tmpdir'
require 'uri'
Sketchup.require(File.join(__dir__, 'su_mcp_bridge'))
Sketchup.require(File.join(__dir__, 'render_scene'))
Sketchup.require(File.join(__dir__, 'image_review'))

module NepNhaDesign
  module Setup
    TITLE = 'Nếp Nhà Design'
    ROOT = File.expand_path(__dir__)
    WINDOWS = Sketchup.platform == :platform_win
    DATA_DIR = if WINDOWS
                 File.join(ENV.fetch('LOCALAPPDATA') { File.join(Dir.home, 'AppData', 'Local') }, 'NepNhaDesign')
               else
                 File.join(Dir.home, 'Library', 'Application Support', 'NepNhaDesign')
               end.freeze
    LOG_PATH = File.join(DATA_DIR, 'cai-dat.log').freeze
    CONFIG_PATH = File.join(DATA_DIR, 'cau-hinh-mcp.json').freeze
    CHAT_HTML_PATH = File.join(ROOT, 'chat.html').freeze
    CHAT_WORKER_PATH = File.join(ROOT, 'chat_worker.py').freeze
    SKILLS_DIR = File.join(DATA_DIR, 'design-skills').freeze
    SHARED_SKILLS_SETTING = 'SharedSkillsDirectory'
    MCP_SERVER_PATH = File.join(ROOT, 'mcp_server.py').freeze
    VERSION = '1.15.0'
    DEFAULT_REPOSITORY = 'Shmily1905/nep_nha_design'

    class << self
      def install_and_check(open_chat_after = false)
        if @installing
          UI.messagebox('Đang cài đặt. Hãy giữ SketchUp mở và đợi thông báo kết quả.')
          return
        end
        unless Bridge.start
          UI.messagebox('Không mở được cổng 9876. Hãy đóng bản cầu nối cũ rồi thử lại.')
          return
        end

        queue = Queue.new
        @installing = true
        Thread.new do
          begin
            queue << install_python_server
          rescue StandardError => e
            queue << [false, "#{e.class}: #{e.message}"]
          end
        end
        timer = UI.start_timer(0.25, true) do
          begin
            result = queue.pop(true)
          rescue ThreadError
            next
          end
          UI.stop_timer(timer)
          @installing = false
          if result.first && open_chat_after
            show_chat
          else
            show_setup_dialog(*result)
          end
        end
      end

      def open_chat
        unless Bridge.start
          UI.messagebox('Không bật được cầu nối SketchUp. Xem Ruby Console để biết chi tiết.')
          return
        end
        if File.file?(python_path)
          show_chat
        else
          install_and_check(true)
        end
      end

      def show_config
        if File.file?(CONFIG_PATH)
          show_setup_dialog(true, 'Cấu hình MCP đã tạo. Bạn không cần dùng phần này khi chat trực tiếp trong SketchUp.')
        else
          UI.messagebox('Hãy chọn “Cài và kiểm tra” trước để tạo cấu hình MCP.')
        end
      end

      def choose_shared_skills
        local = local_skills_dir
        current = shared_skills_dir
        selected = UI.select_directory(
          title: 'Chọn thư mục design-skills dùng chung',
          directory: File.directory?(current) ? current : local
        )
        return unless selected

        selected = File.expand_path(selected)
        unless File.identical?(selected, local)
          Dir.glob('*.md', base: local).each do |name|
            path = File.join(local, name)
            next unless File.file?(path) && !File.symlink?(path)

            target = File.join(selected, File.basename(path))
            begin
              File.open(target, File::WRONLY | File::CREAT | File::EXCL | File::BINARY) do |file|
                file.write(File.binread(path))
              end
            rescue Errno::EEXIST
              next
            end
          end
        end
        path = File.identical?(selected, local) ? '' : selected
        Sketchup.write_default('NepNhaDesign', SHARED_SKILLS_SETTING, path)
        UI.messagebox("Kho skill đang dùng:\n#{selected}")
      rescue StandardError => e
        UI.messagebox("Không đặt được kho skill: #{e.message}")
      end

      private

      def python_path
        File.join(DATA_DIR, 'python-mcp', WINDOWS ? 'Scripts/python.exe' : 'bin/python')
      end

      def background_python_path
        return python_path unless WINDOWS

        executable = File.join(File.dirname(python_path), 'pythonw.exe')
        raise IOError, 'Thiếu pythonw.exe. Hãy chọn Extensions → Nếp Nhà Design → Cài và kiểm tra.' unless File.file?(executable)

        executable
      end

      def python_candidates
        if WINDOWS
          [['py', '-3'], ['python'], ['python3']]
        else
          paths = ['/opt/homebrew/bin/python3', '/usr/local/bin/python3']
          paths.concat(Dir.glob('/Library/Frameworks/Python.framework/Versions/3.*/bin/python3').sort.reverse)
          (paths + ['python3']).uniq.map { |path| [path] }
        end
      end

      def install_python_server
        FileUtils.mkdir_p(DATA_DIR)
        File.open(LOG_PATH, 'w') do |log|
          python = python_candidates.find do |candidate|
            system(*candidate, '-c', 'import sys, venv; sys.exit(sys.version_info < (3, 11))',
                   in: File::NULL, out: log, err: log)
          end
          unless python
            return [false, 'Cần cài Python 3.11 trở lên từ python.org. Sau khi cài, mở lại SketchUp.']
          end

          script = File.join(ROOT, 'cai_dat_mcp.py')
          ok = system({ 'PYTHONUTF8' => '1' }, *python, '-u', script, DATA_DIR,
                      in: File::NULL, out: log, err: log)
          return [true, 'Kết nối Python ↔ SketchUp thành công.'] if ok
        end

        [false, "Cài đặt chưa thành công. Nhật ký nằm ở:\n#{LOG_PATH}"]
      end

      def show_chat
        if @chat_dialog&.visible?
          @chat_dialog.bring_to_front
          check_open_update
          return
        end

        @provider_threads = {}
        @render_dir = Dir.mktmpdir('nep-nha-render-')
        @render_source = @render_signature = @render_selected = nil
        @chat_dialog = UI::HtmlDialog.new(
          dialog_title: 'Trợ lý AI Nếp Nhà', width: 510, height: 890,
          min_width: 370, min_height: 620, resizable: true,
          preferences_key: 'NepNhaDesign.Assistant', style: UI::HtmlDialog::STYLE_UTILITY
        )
        @chat_dialog.set_file(CHAT_HTML_PATH)
        @chat_dialog.add_action_callback('nep_nha_send') { |_context, raw| receive_chat(raw) }
        @chat_dialog.add_action_callback('nep_nha_read_wall') do |_context|
          model = Sketchup.active_model
          id = model.selection.to_a.first&.persistent_id
          begin
            result = Bridge.inspect_wall(model, { 'wall_id' => id })
          rescue StandardError => e
            result = { error: e.message }
          end
          @chat_dialog.execute_script("window.NepNhaChat.wallRead(#{JSON.generate(result)})")
        end
        @chat_dialog.add_action_callback('nep_nha_save_skill') { |_context, content| save_skill(content) }
        # Keep plan and reference picking on separate callback names. This
        # avoids role arguments being misrouted by SketchUp's HtmlDialog.
        @chat_dialog.add_action_callback('nep_nha_pick_plan') { |_context| pick_attachment('plan') }
        @chat_dialog.add_action_callback('nep_nha_pick_geometry') { |_context| pick_attachment('geometry') }
        @chat_dialog.add_action_callback('nep_nha_render_watch') do |_context, enabled|
          render_watch(enabled == true)
        end
        @chat_dialog.add_action_callback('nep_nha_render_scene') do |_context, id|
          next if @render_processing || @chat_busy

          @render_source = nil
          if id.empty?
            @render_selected = nil
            preview_render_scene(true)
          else
            select_render_scene(id)
          end
        end
        @chat_dialog.add_action_callback('nep_nha_render_pick') { |_context| pick_render_image }
        @chat_dialog.add_action_callback('nep_nha_export_render') do |_context, ratio|
          export_render(ratio)
        end
        @chat_dialog.add_action_callback('nep_nha_render_web') do |_context, provider|
          url = { 'chatgpt' => 'https://chatgpt.com/', 'gemini' => 'https://gemini.google.com/app' }[provider]
          UI.openURL(url) if url
        end
        @chat_dialog.add_action_callback('nep_nha_pick_reference') do |_context|
          pick_attachment('reference')
        end
        @chat_dialog.add_action_callback('nep_nha_skills') do |_context|
          directory = skills_dir
          unless File.directory?(directory)
            UI.messagebox("Kho skill dùng chung đang ngoại tuyến:\n#{directory}")
            next
          end
          prefix = WINDOWS ? 'file:///' : 'file://'
          path = URI::DEFAULT_PARSER.escape(directory.tr('\\', '/'), /[^A-Za-z0-9\-._~:\/]/)
          UI.openURL(prefix + path)
        end
        @chat_dialog.add_action_callback('nep_nha_reset') { |_context| reset_chat }
        @chat_dialog.add_action_callback('nep_nha_cancel_image_review') { |_context| @image_review = nil }
        @chat_dialog.add_action_callback('nep_nha_auth_status') do |_context|
          repository = Sketchup.read_default('NepNhaDesign', 'UpdateRepository', DEFAULT_REPOSITORY)
          @chat_dialog.execute_script("window.NepNhaChat.repository(#{JSON.generate(repository)})")
          run_panel_task('auth', { action: 'auth', codex_candidates: codex_candidates })
          check_open_update
        end
        @chat_dialog.add_action_callback('nep_nha_login') { |_context| login_chatgpt }
        @chat_dialog.add_action_callback('nep_nha_install_codex') { |_context| install_codex }
        @chat_dialog.add_action_callback('nep_nha_models') do |_context|
          run_panel_task('models', { action: 'models', codex_path: @codex_path })
        end
        @chat_dialog.add_action_callback('nep_nha_gemini_catalog') do |_context|
          run_panel_task('geminiCatalog', { action: 'gemini_catalog', agy_candidates: agy_candidates })
        end
        @chat_dialog.add_action_callback('nep_nha_gemini_efforts') do |_context, model|
          run_panel_task('geminiEfforts', { action: 'gemini_efforts', agy_path: @agy_path, model: model })
        end
        @chat_dialog.add_action_callback('nep_nha_gemini_help') do |_context|
          UI.openURL('https://antigravity.google/docs/install?tab=cli')
        end
        @chat_dialog.add_action_callback('nep_nha_update') do |_context, action, repository, version|
          next unless %w[check_update download_update].include?(action)

          start_update(action, repository, version)
        end
        @chat_dialog.add_action_callback('nep_nha_github') do |_context, action, repository, token|
          next unless %w[github_status github_save github_logout].include?(action)

          payload = { action: action, repository: repository }
          payload[:token] = token.to_s if action == 'github_save'
          run_panel_task('github', payload)
        end
        @chat_dialog.add_action_callback('nep_nha_github_token') do |_context, repository|
          owner = repository.to_s.split('/', 2).first
          owner = DEFAULT_REPOSITORY.split('/', 2).first unless owner.match?(/\A[A-Za-z0-9-]+\z/)
          query = [
            'name=Nep+Nha+Design+Updater',
            'description=Read+private+releases+for+SketchUp+updates',
            "target_name=#{CGI.escape(owner)}",
            'expires_in=366',
            'contents=read'
          ].join('&')
          UI.openURL("https://github.com/settings/personal-access-tokens/new?#{query}")
        end
        @chat_dialog.set_on_closed do
          @image_review = nil
          render_watch(false)
          directory = @render_dir
          if @chat_busy || @render_processing
            cleanup = UI.start_timer(0.5, true) do
              next if @chat_busy || @render_processing

              UI.stop_timer(cleanup)
              FileUtils.remove_entry(directory) if File.directory?(directory)
            end
          elsif File.directory?(directory)
            FileUtils.remove_entry(directory)
          end
          @chat_dialog = nil
        end
        @chat_dialog.show
      rescue StandardError => e
        UI.messagebox("Không mở được bảng chat: #{e.message}")
      end

      def check_open_update
        repository = Sketchup.read_default('NepNhaDesign', 'UpdateRepository', DEFAULT_REPOSITORY)
        start_update('auto_update', repository)
      end

      def start_update(action, repository, version = nil)
        return if @update_in_progress
        if @installed_version
          message = "Đã cài v#{@installed_version}. Mở lại SketchUp để dùng bản mới."
          @chat_dialog.execute_script("window.NepNhaChat.update(#{JSON.generate(ok: true, installed: true, message: message)})")
          return
        end

        @update_in_progress = true
        @chat_dialog.execute_script('window.NepNhaChat.updateStarted()')
        run_panel_task('update', { action: action, repository: repository,
                                  version: VERSION, expected_version: version })
      end

      def pick_attachment(role)
        is_plan = role == 'plan'
        filter = is_plan ? 'Mặt bằng|*.pdf;*.png;*.jpg;*.jpeg;*.webp||' : 'Ảnh|*.png;*.jpg;*.jpeg;*.webp||'
        title = { 'plan' => 'Chọn mặt bằng', 'geometry' => 'Chọn ảnh mẫu dựng hình' }.fetch(role, 'Chọn ảnh tham chiếu')
        path = UI.openpanel(title, '', filter)
        return unless path

        allowed = %w[.png .jpg .jpeg .webp]
        allowed << '.pdf' if is_plan
        unless allowed.include?(File.extname(path).downcase)
          message = if is_plan
                      'Mặt bằng hỗ trợ PDF, PNG, JPG, JPEG hoặc WebP.'
                    else
                      'Ảnh chỉ hỗ trợ PNG, JPG, JPEG hoặc WebP.'
                    end
          UI.messagebox(message)
          return
        end

        data = JSON.generate({ role: role, path: path, name: File.basename(path) })
        @chat_dialog.execute_script("window.NepNhaChat.attach(#{data})")
      end

      def receive_chat(raw)
        return unless @chat_dialog
        if @installed_version
          send_to_chat(ok: false, error: "Đã cài v#{@installed_version}. Lưu bản vẽ và mở lại SketchUp để tiếp tục.")
          return
        end
        if @chat_busy
          send_to_chat(ok: false, error: 'Trợ lý đang xử lý yêu cầu trước.')
          return
        end

        request = JSON.parse(raw)
        if request.key?('image_review_id')
          approve_image_review(request, Sketchup.active_model)
          return
        end
        model_id = request['model'].to_s
        gemini = model_id.start_with?('google:')
        @provider_threads ||= {}
        provider = gemini ? 'gemini' : 'gpt'
        thread_id = @provider_threads[provider]
        draft = request['draft_skill'] == true
        raise ArgumentError, 'Hãy trao đổi về quy tắc thiết kế trước khi soạn skill.' if draft && !thread_id

        prompt = request['prompt'].to_s.strip
        raise ArgumentError, 'Nội dung cần từ 1 đến 10.000 ký tự.' unless prompt.length.between?(1, 10_000)
        if gemini
          raise ArgumentError, 'Hãy kết nối Antigravity trước khi chọn Gemini.' unless @agy_path
        elsif !@codex_path
          raise ArgumentError, 'Hãy kiểm tra trạng thái tài khoản ChatGPT trước khi gửi.'
        end

        payload = {
          prompt: prompt, thread_id: thread_id, codex_path: @codex_path, agy_path: @agy_path,
          model: model_id, effort: request['effort'].to_s,
          python_path: background_python_path, mcp_server_path: MCP_SERVER_PATH, data_dir: DATA_DIR,
          fast: request['fast'] == true, images: request.fetch('images', []), skills_dir: skills_dir,
          local_skills_dir: local_skills_dir, draft_skill: draft,
          selection: Bridge.selection_info(Sketchup.active_model),
          pdf_page: request.fetch('pdf_page', 1), pdf_pages: request.fetch('pdf_pages', [])
        }
        if request['render'] == true
          payload[:action] = 'render'
          payload[:thread_id] = nil
          payload[:render_ratio] = request['render_ratio']
          payload[:render_crop] = render_crop_request(request['render_ratio'])
          payload[:prompt] = "#{prompt}\n#{@render_source[:legend]}"
        end
        model = Sketchup.active_model
        if @plan_model == model && @plan_context && !payload[:action] && !draft
          payload[:plan_context] = @plan_context
        end
        if request['image_geometry'] == true && !payload[:action] && !draft
          raise ArgumentError, 'Hãy mở một model SketchUp để dựng hình.' unless model
          raise ArgumentError, 'Hãy thoát chế độ chỉnh sửa group trước khi dựng.' if model.active_path

          image_review_request(payload)
        elsif request['auto_exterior'] == true
          raise ArgumentError, 'Hãy thoát chế độ chỉnh sửa group trước khi dựng.' if model.active_path

          payload[:action] = 'auto_exterior'
          payload[:thread_id] = nil
          payload[:review_floors] = request['review_floors']
          payload[:plan_latest] = request['plan_latest']
          payload[:pending_plan_floor] = request['pending_plan_floor']
          payload[:omitted_plan_floors] = request['omitted_plan_floors']
          payload[:plan_schema] = 1
        end
        dialog = @chat_dialog
        @chat_busy = true
        queue = Queue.new
        Thread.new { queue << run_chat_worker(payload) }
        timer = UI.start_timer(0.2, true) do
          begin
            result = queue.pop(true)
          rescue ThreadError
            next
          end
          UI.stop_timer(timer)
          @chat_busy = false
          next unless dialog.equal?(@chat_dialog) && dialog.visible?

          build = result.delete('exterior_build')
          plan_context = result.delete('plan_context')
          if build
            begin
              unless Sketchup.active_model == model && !model.active_path
                raise ArgumentError, 'Model hoặc vùng chỉnh sửa đã đổi. Hãy gửi lại yêu cầu.'
              end

              built = Bridge.build_model(model, build)
              @plan_model = model
              @plan_context = plan_context.merge('group_id' => built.fetch(:persistent_id))
              names = plan_context.fetch('levels').map { |level| level.fetch('name') }.join(', ')
              summary = "Đã dựng #{names} và lắp #{build.fetch('openings').length} bộ cửa."
              roof = plan_context.fetch('roof')
              if plan_context['roof_deferred']
                next_step = 'Bạn muốn tôi dựng mái theo thông số đã chốt hay chỉnh phần nào trước?'
                result['text'] = [summary, result['text'], next_step].reject(&:empty?).join("\n")
              else
                summary += " Mái dốc #{roof.fetch('pitch_deg')}°, vươn #{roof.fetch('overhang_mm')} mm."
                result['text'] = [summary, result['text']].reject(&:empty?).join("\n")
              end
            rescue StandardError => e
              result['ok'] = false
              result['error'] = "Không dựng được nhà: #{e.message}"
            end
          end
          if result['ok'] && result['thread_id'] && !payload[:action]
            @provider_threads[provider] = result['thread_id']
          end
          if payload[:action] == 'image_review' && result['ok'] && result['image_review']
            id = SecureRandom.hex(16)
            @image_review = { id: id, model: model, payload: payload,
                              proposal: result['image_review'], frame: result.delete('image_frame') }
            result['image_review_id'] = id
          end
          result['exterior'] = true if payload[:action] == 'auto_exterior'
          result['draft_skill'] = draft if result['ok']
          send_to_chat(result)
        end
      rescue JSON::ParserError, ArgumentError => e
        send_to_chat(ok: false, error: e.message)
      rescue StandardError => e
        send_to_chat(ok: false, error: "Lỗi bảng chat: #{e.message}")
      end

      def skills_dir
        shared = shared_skills_dir
        shared.empty? ? local_skills_dir : shared
      end

      def shared_skills_dir
        Sketchup.read_default('NepNhaDesign', SHARED_SKILLS_SETTING, '').to_s
      end

      def local_skills_dir
        FileUtils.mkdir_p(SKILLS_DIR)
        Dir.glob(File.join(ROOT, 'design-skills', '*.md')).each do |path|
          target = File.join(SKILLS_DIR, File.basename(path))
          FileUtils.cp(path, target) unless File.exist?(target)
        end
        SKILLS_DIR
      end

      def save_skill(content)
        body = content.to_s.strip
        unless body.bytesize.between?(1, 32_767) && body.start_with?('# ')
          raise ArgumentError, 'Skill cần tiêu đề Markdown bắt đầu bằng # và dung lượng dưới 32 KB.'
        end

        directory = skills_dir
        unless File.directory?(directory)
          raise ArgumentError, 'Kho skill dùng chung đang ngoại tuyến. Kết nối lại Google Drive để lưu bản nháp.'
        end
        used = Dir.glob('*.md', base: directory).sum do |name|
          path = File.join(directory, name)
          File.file?(path) && !File.symlink?(path) ? File.size(path) : 0
        end
        raise ArgumentError, 'Kho skill đã đạt giới hạn 128 KB.' if used + body.bytesize + 1 > 131_072

        filename = "skill-#{Time.now.strftime('%Y%m%d')}-#{SecureRandom.hex(4)}.md"
        File.open(File.join(directory, filename), File::WRONLY | File::CREAT | File::EXCL | File::BINARY) do |file|
          file.write(body + "\n")
        end
        @chat_dialog.execute_script("window.NepNhaChat.skillSaved(#{JSON.generate({ name: filename })})")
      rescue StandardError => e
        @chat_dialog.execute_script("window.NepNhaChat.skillSaved(#{JSON.generate({ error: e.message })})")
      end

      def run_chat_worker(payload)
        FileUtils.mkdir_p(DATA_DIR)
        task_id = "#{Process.pid}-#{SecureRandom.hex(8)}"
        request_path = File.join(DATA_DIR, "chat-request-#{task_id}.json")
        result_path = File.join(DATA_DIR, "chat-result-#{task_id}.json")
        payload = payload.merge(data_dir: DATA_DIR, result_path: result_path)
        secret_request = payload.key?(:token)
        arguments = [background_python_path, '-I', '-X', 'utf8', '-u', CHAT_WORKER_PATH]
        if secret_request
          stdout_text, stderr_text, status = Open3.capture3(
            *arguments, stdin_data: JSON.generate(payload).encode(Encoding::UTF_8), binmode: true
          )
        else
          File.binwrite(request_path, JSON.generate(payload).encode(Encoding::UTF_8))
          stdout_text, stderr_text, status = Open3.capture3(*arguments, request_path, binmode: true)
        end
        output = if File.file?(result_path)
                   File.binread(result_path).force_encoding(Encoding::UTF_8)
                 else
                   stdout_text.force_encoding(Encoding::UTF_8)
                 end
        if status.success?
          response = JSON.parse(output)
          return response if response.is_a?(Hash) && [true, false].include?(response['ok'])

          return { 'ok' => false, 'error' => 'NN131: Tiến trình chat trả về sai cấu trúc.' }
        end

        { 'ok' => false, 'error' => "NN132: Không khởi chạy được tiến trình chat (mã thoát #{status.exitstatus})." }
      rescue JSON::ParserError
        detail = stderr_text.to_s.lines.last(4).join.strip
        { 'ok' => false, 'error' => "NN141: Không đọc được kết quả (#{output.to_s.bytesize} byte). #{detail}".strip }
      rescue StandardError => e
        { 'ok' => false, 'error' => "Không chạy được trợ lý AI: #{e.message}" }
      ensure
        FileUtils.rm_f(request_path) if request_path
        FileUtils.rm_f(result_path) if result_path
      end

      def run_panel_task(channel, payload, token = nil)
        queue = Queue.new
        dialog = @chat_dialog
        Thread.new { queue << run_chat_worker(payload) }
        timer = UI.start_timer(0.25, true) do
          next if channel == 'update' && @chat_busy

          begin
            result = queue.pop(true)
          rescue ThreadError
            next
          end
          UI.stop_timer(timer)
          @render_processing = false if channel == 'renderExport'
          @update_in_progress = false if channel == 'update'
          path = result.delete('path')
          begin
            if path && channel == 'update'
              installed = Sketchup.install_from_archive(path)
              @installed_version = result['version'] if installed
              result = installed ?
                { ok: true, installed: true, message: "Đã cài v#{@installed_version}. Lưu bản vẽ và mở lại SketchUp để dùng bản mới." } :
                { ok: false, error: 'SketchUp chưa chấp nhận gói cập nhật.' }
            end
          rescue StandardError => e
            result = { ok: false, error: "Không cài được bản cập nhật: #{e.message}" }
          ensure
            FileUtils.rm_f(path) if path
          end
          if dialog.equal?(@chat_dialog) && dialog.visible?
            if channel == 'update' && payload[:action] == 'check_update' && result['ok']
              Sketchup.write_default('NepNhaDesign', 'UpdateRepository', payload[:repository])
            end
            if channel == 'github' && payload[:action] == 'github_save' && result['ok'] && result['state'] == 'ready'
              Sketchup.write_default('NepNhaDesign', 'UpdateRepository', payload[:repository])
              check_open_update
            end
            if channel == 'auth'
              @codex_path = result.delete('codex_path')
              result['message'] ||= result['error']
            end
            @agy_path = result.delete('agy_path') if channel == 'geminiCatalog'
            dialog.execute_script("window.NepNhaChat.#{channel}(#{JSON.generate(result)}, #{JSON.generate(token)})")
          end
        end
      end

      def reset_chat
        @image_review = nil
        @provider_threads = {}
        @plan_model = @plan_context = nil
        send_to_chat(ok: true, reset: true)
      end

      def agy_candidates
        candidates = [ENV['NEP_NHA_AGY_PATH']]
        if WINDOWS
          local = ENV['LOCALAPPDATA'].to_s
          candidates << File.join(local, 'agy', 'bin', 'agy.exe') unless local.empty?
          candidates << 'agy.exe'
        else
          candidates.concat(['/opt/homebrew/bin/agy', '/usr/local/bin/agy', 'agy'])
        end
        candidates.compact.uniq
      end

      def codex_candidates
        candidates = []
        candidates << ENV['NEP_NHA_CODEX_PATH'] if ENV['NEP_NHA_CODEX_PATH']
        if WINDOWS
          local = ENV['LOCALAPPDATA'].to_s
          candidates << File.join(local, 'Programs', 'OpenAI', 'Codex', 'bin', 'codex.exe') unless local.empty?
          candidates << File.join(local, 'Microsoft', 'WindowsApps', 'codex.exe') unless local.empty?
          candidates.concat(['codex.exe', 'codex'])
        else
          candidates.concat(['/opt/homebrew/bin/codex', '/usr/local/bin/codex', 'codex'])
        end
        candidates.compact.uniq
      end

      def codex_path(refresh = false)
        @codex_path = nil if refresh
        return @codex_path if @codex_path

        @codex_path = codex_candidates.find do |candidate|
          next false if candidate.include?(File::SEPARATOR) && !File.file?(candidate)

          _out, _err, status = Open3.capture3(candidate, '--version')
          status.success?
        rescue SystemCallError
          false
        end
      end

      def codex_logged_in?(executable)
        output, errors, status = Open3.capture3(executable, 'login', 'status')
        status.success? && "#{output}\n#{errors}".match?(/logged in using chatgpt/i)
      rescue SystemCallError
        false
      end

      def login_chatgpt
        executable = codex_path
        unless executable
          send_auth_to_chat(state: 'missing', message: 'Hãy cài thành phần ChatGPT trước.')
          return
        end
        if @auth_busy
          send_auth_to_chat(state: 'working', message: 'Đang chờ đăng nhập trong trình duyệt…')
          return
        end

        @auth_busy = true
        send_auth_to_chat(state: 'working', message: 'Trình duyệt sẽ mở. Hãy đăng nhập và cho phép kết nối.')
        run_background_auth do
          _out, error, status = capture_with_timeout([executable, 'login'], 300)
          if status&.success? && codex_logged_in?(executable)
            { state: 'ready', message: 'Đăng nhập thành công. Bạn có thể chat ngay.' }
          else
            detail = error.to_s.lines.last(6).join.strip
            { state: 'signed_out', message: detail.empty? ? 'Đăng nhập chưa hoàn tất. Hãy thử lại.' : detail }
          end
        end
      end

      def install_codex
        unless WINDOWS
          UI.openURL('https://developers.openai.com/codex/cli')
          send_auth_to_chat(state: 'missing', message: 'Đã mở hướng dẫn cài Codex chính thức cho máy của bạn.')
          return
        end
        if @auth_busy
          send_auth_to_chat(state: 'working', message: 'Một tác vụ cài đặt/đăng nhập đang chạy…')
          return
        end

        @auth_busy = true
        send_auth_to_chat(state: 'working', message: 'Đang cài thành phần ChatGPT chính thức. Vui lòng chờ…')
        command = "$env:CODEX_NON_INTERACTIVE='1'; irm https://chatgpt.com/codex/install.ps1 | iex"
        run_background_auth do
          _out, error, status = capture_with_timeout(
            ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command], 300
          )
          executable = codex_path(true)
          if status&.success? && executable
            { state: 'signed_out', message: 'Cài xong. Bây giờ bấm “Tiếp tục với ChatGPT”.' }
          else
            detail = error.to_s.lines.last(8).join.strip
            { state: 'missing', message: detail.empty? ? 'Cài đặt chưa thành công.' : detail }
          end
        end
      end

      def run_background_auth(&block)
        queue = Queue.new
        Thread.new do
          result = block.call
          queue << result
        rescue StandardError => e
          queue << { state: 'error', message: "Lỗi: #{e.message}" }
        end
        timer = UI.start_timer(0.25, true) do
          begin
            result = queue.pop(true)
          rescue ThreadError
            next
          end
          UI.stop_timer(timer)
          @auth_busy = false
          send_auth_to_chat(result)
        end
      end

      def capture_with_timeout(command, seconds)
        stdout_text = ''
        stderr_text = ''
        status = nil
        Open3.popen3(*command) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          stdout_reader = Thread.new { stdout.read }
          stderr_reader = Thread.new { stderr.read }
          begin
            Timeout.timeout(seconds) { status = wait_thread.value }
          rescue Timeout::Error
            Process.kill('TERM', wait_thread.pid)
            wait_thread.join(5)
          ensure
            stdout_text = stdout_reader.value
            stderr_text = stderr_reader.value
          end
        end
        [stdout_text, stderr_text, status]
      end

      def send_auth_to_chat(payload = nil, **keywords)
        payload ||= keywords
        return unless @chat_dialog&.visible?

        @chat_dialog.execute_script("window.NepNhaChat.auth(#{JSON.generate(payload)})")
      rescue StandardError => e
        warn "[Nếp Nhà Design] Auth UI: #{e.message}"
      end

      def send_to_chat(payload)
        return unless @chat_dialog&.visible?

        @chat_dialog.execute_script("window.NepNhaChat.receive(#{JSON.generate(payload)})")
      rescue StandardError => e
        warn "[Nếp Nhà Design] Chat UI: #{e.message}"
      end

      def show_setup_dialog(ok, message)
        @setup_dialog.close if @setup_dialog&.visible?
        details = if ok && File.file?(CONFIG_PATH)
                    File.read(CONFIG_PATH, encoding: 'UTF-8')
                  elsif File.file?(LOG_PATH)
                    File.readlines(LOG_PATH, encoding: 'UTF-8', invalid: :replace, undef: :replace).last(18).join
                  else
                    ''
                  end
        @setup_dialog = UI::HtmlDialog.new(dialog_title: TITLE, width: 640, height: 420,
                                           resizable: true, style: UI::HtmlDialog::STYLE_DIALOG)
        @setup_dialog.set_html(<<~HTML)
          <!doctype html><html lang="vi"><meta charset="utf-8"><title>#{TITLE}</title>
          <style>body{font:15px system-ui;color:#18251d;background:#f6f7f2;padding:18px}h1{font-size:22px}
          p{white-space:pre-wrap;line-height:1.45}textarea{width:100%;min-height:180px;box-sizing:border-box}</style>
          <h1>#{ok ? 'Cài đặt hoàn tất' : 'Kiểm tra cài đặt'}</h1>
          <p>#{CGI.escapeHTML(message)}</p>
          <textarea readonly>#{CGI.escapeHTML(details)}</textarea></html>
        HTML
        @setup_dialog.show
      rescue StandardError => e
        UI.messagebox("#{message}\n#{e.message}")
      end
    end
  end

  unless file_loaded?(__FILE__)
    menu = UI.menu('Extensions').add_submenu('Nếp Nhà Design')
    menu.add_item('Mở Trợ lý AI') { Setup.open_chat }
    menu.add_separator
    menu.add_item('Cài và kiểm tra') { Setup.install_and_check }
    menu.add_item('Chọn kho skill dùng chung') { Setup.choose_shared_skills }
    command = UI::Command.new('Trợ lý AI Nếp Nhà') { Setup.open_chat }
    command.small_icon = command.large_icon = File.join(Setup::ROOT, 'logo.png')
    command.tooltip = 'Mở Trợ lý AI Nếp Nhà'
    toolbar = UI::Toolbar.new('Nếp Nhà Design')
    toolbar.add_item(command)
    toolbar.restore if toolbar.get_last_state == TB_VISIBLE
    menu.add_item('Xem cấu hình MCP nâng cao') { Setup.show_config }
    menu.add_separator
    menu.add_item('Bật cầu nối SketchUp') { Bridge.start }
    menu.add_item('Tắt cầu nối SketchUp') { Bridge.stop }
    file_loaded(__FILE__)
    Bridge.start
  end
end
