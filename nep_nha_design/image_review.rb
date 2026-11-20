# frozen_string_literal: true

module NepNhaDesign
  module Setup
    IMAGE_STAGES = ['Khối thô từng tầng', 'Ô mở và cửa kính', 'Ban công, mái và lam', 'Màu khối sơ bộ'].freeze

    class << self
      def image_review_request(payload)
        images = payload.fetch(:images)
        unless images.is_a?(Array) && images.all? { |image| image.is_a?(Hash) }
          raise ArgumentError, 'Danh sách ảnh mẫu không hợp lệ.'
        end

        unless images.any? { |image| image['role'] == 'geometry' }
          images = images.map { |image| image['role'] == 'reference' ? image.merge('role' => 'geometry') : image }
        end
        @image_review = nil
        payload.merge!(action: 'image_review', thread_id: nil, images: images, plan_context: nil)
      end

      def approved_image_values(edited, proposal)
        number = lambda do |value, min, max|
          unless value.is_a?(Numeric) && value.between?(min, max)
            raise ArgumentError, 'Kiểm tra lại cao độ, kích thước và tỷ lệ trong bảng.'
          end
          value
        end
        label = lambda do |value|
          unless value.is_a?(String) && value.strip.length.between?(1, 100)
            raise ArgumentError, 'Nhập đầy đủ tên tầng và loại mái.'
          end
          value.strip
        end
        rows = edited.fetch('floors')
        unless rows.is_a?(Array) && rows.length.between?(1, 40) && rows.all? { |row| row.is_a?(Hash) }
          raise ArgumentError, 'Bảng phải có từ 1 đến 40 tầng.'
        end
        floors = rows.map do |row|
          {
            'name' => label.call(row['name']),
            'base_mm' => number.call(row['base_mm'], -1_000_000, 1_000_000),
            'height_mm' => number.call(row['height_mm'], 1, 100_000),
            'balcony_mm' => number.call(row['balcony_mm'], 0, 100_000)
          }
        end
        unless floors.each_cons(2).all? { |lower, upper| upper['base_mm'] > lower['base_mm'] }
          raise ArgumentError, 'Xếp các tầng theo thứ tự cao độ sàn tăng dần.'
        end

        approved = {
          'floors' => floors, 'roof_type' => label.call(edited['roof_type']),
          'roof_overhang_mm' => number.call(edited['roof_overhang_mm'], 0, 100_000),
          'glass_pct' => number.call(edited['glass_pct'], 0, 100),
          'scale_basis' => proposal.fetch('scale_basis'), 'notes' => proposal.fetch('notes')
        }
        %w[column_spacing_mm louver_spacing_mm].each do |field|
          value = edited[field]
          approved[field] = value.nil? ? nil : number.call(value, 1, 100_000)
        end
        approved
      end

      def approve_image_review(request, model)
        pending = @image_review
        unless pending && pending[:id] == request['image_review_id'] && pending[:model] == model && !model.active_path
          raise ArgumentError, 'Bảng đã hết hiệu lực hoặc model đã đổi. Hãy phân tích ảnh lại.'
        end
        edits = request['image_values']
        raise ArgumentError, 'Thiếu thông số duyệt.' unless edits.is_a?(Hash)

        approved = approved_image_values(edits, pending.fetch(:proposal))
        payload = pending.fetch(:payload).merge(
          action: 'image_geometry', model_guard: SecureRandom.hex(16),
          approved_image_review: approved, image_stage: 0
        )
        @image_review = nil
        Bridge.pin_model(payload[:model_guard], model, pending.fetch(:frame))
        run_image_stages(payload, @chat_dialog)
      end

      def run_image_stages(payload, dialog)
        guard = payload.fetch(:model_guard)
        index = payload.fetch(:image_stage)
        Bridge.start_image_stage(guard, index)
        @chat_busy = true
        send_to_chat(image_progress: true, stage: index + 1, label: IMAGE_STAGES.fetch(index))
        queue = Queue.new
        Thread.new { queue << run_chat_worker(payload) }
        timer = UI.start_timer(0.2, true) do
          begin
            result = queue.pop(true)
          rescue ThreadError
            next
          end
          UI.stop_timer(timer)
          continue_image_stages(payload, dialog, result)
        end
      rescue StandardError => e
        finish_image_stages(guard, dialog, { ok: false, error: e.message })
      end

      def continue_image_stages(payload, dialog, result)
        guard = payload.fetch(:model_guard)
        index = payload.fetch(:image_stage)
        unless dialog.equal?(@chat_dialog) && dialog.visible?
          finish_image_stages(guard, dialog, {})
          return
        end
        image = Bridge.image_stage_capture(guard)
        approved = payload.fetch(:approved_image_review)
        required = case index
                   when 1 then approved['glass_pct'] > 0
                   when 2
                     approved['roof_overhang_mm'] > 0 || approved['louver_spacing_mm'] ||
                       approved['floors'].any? { |row| row['balcony_mm'] > 0 }
                   else true
                   end
        built = !required || Bridge.image_stage_built?(guard)
        if result['ok'] && result['stage_complete'] && image && built
          send_to_chat(image_progress: true, stage: index + 1, label: IMAGE_STAGES.fetch(index),
                       text: result['text'], image: image)
          if index + 1 < IMAGE_STAGES.length
            run_image_stages(payload.merge(image_stage: index + 1, thread_id: result['thread_id']), dialog)
          else
            provider = payload[:model].start_with?('google:') ? 'gemini' : 'gpt'
            @provider_threads[provider] = result['thread_id'] if result['thread_id']
            finish_image_stages(guard, dialog, { ok: true, text: 'Đã dựng và đối chiếu đủ bốn lớp.' })
          end
        else
          detail = result['error'] || result['text']
          if result['stage_complete'] && (!image || !built)
            detail = 'Thiếu hình học hoặc ảnh chụp sau lần chỉnh cuối của lớp.'
          end
          finish_image_stages(guard, dialog, result.merge(
            'ok' => false, 'error' => "Dừng ở lớp #{index + 1} – #{IMAGE_STAGES.fetch(index)}. #{detail} " \
                                     'Phần đã dựng được giữ trong model để kiểm tra.'
          ))
        end
      rescue StandardError => e
        finish_image_stages(guard, dialog, { ok: false, error: e.message })
      end

      def finish_image_stages(guard, dialog, result)
        Bridge.release_model_pin(guard)
        @chat_busy = false
        send_to_chat(result.merge(image_build_finished: true)) if dialog.equal?(@chat_dialog) && dialog.visible?
      end
    end
  end
end
