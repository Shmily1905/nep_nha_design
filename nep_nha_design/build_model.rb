# frozen_string_literal: true

module NepNhaDesign
  module Bridge
    class << self
      def prepare_hip_roof_face(model, params)
        id = params['roof_id']
        polygon = params['footprint_mm']
        elevation = params['elevation_mm']
        unless id.is_a?(String) && id.match?(/\A[a-zA-Z0-9_-]{1,64}\z/) &&
               valid_footprint?(polygon) && elevation.is_a?(Numeric) &&
               elevation.between?(-100_000, 100_000)
          raise RPCError.new(-32602, 'Invalid roof ID, footprint or elevation')
        end

        group = model.entities.grep(Sketchup::Group).find do |item|
          item.get_attribute('NepNhaDesign', 'hip_roof_id') == id
        end
        if model.active_path && (!group || model.active_path != [group])
          raise RPCError.new(-32001, 'Exit the current group before preparing a roof face')
        end

        fingerprint = Digest::SHA256.hexdigest(JSON.generate([polygon, elevation]))
        if group
          face = model.find_entity_by_persistent_id(group.get_attribute('NepNhaDesign', 'hip_roof_face_id'))
          unless group.get_attribute('NepNhaDesign', 'hip_roof_input') == fingerprint &&
                 face.is_a?(Sketchup::Face) && group.entities.to_a.include?(face)
            raise RPCError.new(-32602, 'Roof ID is already in use. Check the existing roof before trying again.')
          end
        else
          group, face = with_operation(model) do
            item = model.entities.add_group
            item.name = 'Mái - 1001bit Pro'
            points = polygon.map { |x, y| Geom::Point3d.new(x.mm, y.mm, elevation.mm) }
            surface = item.entities.add_face(points)
            unless surface && surface.vertices.length == points.length
              raise RPCError.new(-32602, 'Roof footprint must be a single closed polygon')
            end

            surface.reverse! if surface.normal.z < 0
            item.set_attribute('NepNhaDesign', 'hip_roof_id', id)
            item.set_attribute('NepNhaDesign', 'hip_roof_input', fingerprint)
            item.set_attribute('NepNhaDesign', 'hip_roof_face_id', surface.persistent_id)
            [item, surface]
          end
        end

        model.active_path = [group] unless model.active_path
        model.selection.clear
        model.selection.add(face)
        { roof_id: id, group_id: group.persistent_id, face_id: face.persistent_id,
          elevation_mm: elevation, status: 'face_selected', next_tool: '1001bit Pro / Create Hip Roof' }
      end

      def build_model(model, params)
        raise RPCError.new(-32001, 'Exit group editing before building') if model.active_path

        id = params['build_id']
        name = params['name']
        scale = params['scale_basis']
        solids = params['solids']
        unless id.is_a?(String) && id.match?(/\A[a-zA-Z0-9_-]{1,64}\z/) &&
               name.is_a?(String) && name.length.between?(1, 100) &&
               scale.is_a?(String) && scale.strip.length.between?(1, 500) &&
               solids.is_a?(Array) && solids.length.between?(1, 200)
          raise RPCError.new(-32602, 'Invalid build ID, name, scale basis or solid count')
        end

        fingerprint = Digest::SHA256.hexdigest(JSON.generate(params))
        existing = model.entities.grep(Sketchup::Group).find do |group|
          group.get_attribute('NepNhaDesign', 'build_id') == id
        end
        if existing
          unless existing.get_attribute('NepNhaDesign', 'fingerprint') == fingerprint
            raise RPCError.new(-32602, 'Build ID already exists with a different plan')
          end
          return build_summary(existing, id, scale, false)
        end

        solids.each_with_index { |solid, index| validate_solid(solid, index + 1) }
        with_operation(model) do
          root = model.entities.add_group
          root.name = name
          root.set_attribute('NepNhaDesign', 'build_id', id)
          root.set_attribute('NepNhaDesign', 'fingerprint', fingerprint)
          root.set_attribute('NepNhaDesign', 'scale_basis', scale)
          palette = {}
          categories = {}
          labels = {
            'roof' => 'Mái', 'wall' => 'Tường', 'floor' => 'Sàn', 'door' => 'Cửa đi',
            'window' => 'Cửa sổ', 'planter' => 'Bồn cây'
          }
          solids.each do |solid|
            category = solid['category']
            parent = root
            if labels.key?(category)
              parent = categories[category] ||= root.entities.add_group.tap { |item| item.name = labels.fetch(category) }
            end
            group = parent.entities.add_group
            group.name = solid.fetch('name')
            points = solid.fetch('footprint_mm').map do |x, y|
              Geom::Point3d.new(x.mm, y.mm, solid.fetch('base_mm').mm)
            end
            face = group.entities.add_face(points)
            raise RPCError.new(-32602, "Invalid footprint for #{group.name}") unless face

            face.reverse! if face.normal.z < 0
            face.pushpull(solid.fetch('height_mm').mm)
            bounds = group.bounds
            bottom = solid.fetch('base_mm')
            top = bottom + solid.fetch('height_mm')
            unless group.manifold? && (bounds.min.z.to_mm - bottom).abs < 0.1 &&
                   (bounds.max.z.to_mm - top).abs < 0.1
              raise RPCError.new(-32602, "Could not extrude #{group.name}")
            end
            color = solid.fetch('hex_color').upcase
            opacity = solid.fetch('opacity', 1.0).to_f
            group.material = palette[[color, opacity]] ||= begin
              material = model.materials.add("Nếp Nhà #{color} #{opacity}")
              material.color = Sketchup::Color.new(*color[1..].scan(/../).map { |part| part.to_i(16) })
              material.alpha = opacity
              material
            end
          end
          build_summary(root, id, scale, true)
        end
      end

      def validate_solid(solid, index)
        if solid.is_a?(Hash)
          polygon = solid['footprint_mm']
          name = solid['name']
          color = solid['hex_color']
          opacity = solid.fetch('opacity', 1.0)
          return if name.is_a?(String) && name.length.between?(1, 100) && valid_footprint?(polygon) &&
                    color.is_a?(String) && color.match?(/\A#[0-9a-fA-F]{6}\z/) &&
                    opacity.is_a?(Numeric) && opacity.between?(0, 1) &&
                    solid['base_mm'].is_a?(Numeric) && solid['base_mm'].between?(-100_000, 100_000) &&
                    solid['height_mm'].is_a?(Numeric) && solid['height_mm'].between?(1, 100_000)
        end
        raise RPCError.new(-32602, "Invalid solid at position #{index}")
      end

      def valid_footprint?(polygon)
        polygon.is_a?(Array) && polygon.length.between?(3, 32) &&
          polygon.uniq.length == polygon.length &&
          polygon.all? do |point|
            point.is_a?(Array) && point.length == 2 &&
              point.all? { |value| value.is_a?(Numeric) && value.between?(-1_000_000, 1_000_000) }
          end
      end

      def build_summary(group, id, scale, created)
        bounds = group.bounds
        {
          build_id: id, persistent_id: group.persistent_id, created: created, units: 'mm',
          scale_basis: scale, solid_count: group.entities.grep(Sketchup::Group).sum { |child|
            nested = child.entities.grep(Sketchup::Group)
            nested.empty? ? 1 : nested.length
          },
          bounds_mm: { min: point_mm(bounds.min), max: point_mm(bounds.max) }
        }
      end
    end
  end
end
