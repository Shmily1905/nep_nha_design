# frozen_string_literal: true

module NepNhaDesign
  module Bridge
    class << self
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
          valid_polygon = polygon.is_a?(Array) && polygon.length.between?(3, 32) &&
                          polygon.uniq.length == polygon.length &&
                          polygon.all? do |point|
                            point.is_a?(Array) && point.length == 2 &&
                              point.all? { |value| value.is_a?(Numeric) && value.between?(-1_000_000, 1_000_000) }
                          end
          return if name.is_a?(String) && name.length.between?(1, 100) && valid_polygon &&
                    color.is_a?(String) && color.match?(/\A#[0-9a-fA-F]{6}\z/) &&
                    opacity.is_a?(Numeric) && opacity.between?(0, 1) &&
                    solid['base_mm'].is_a?(Numeric) && solid['base_mm'].between?(-100_000, 100_000) &&
                    solid['height_mm'].is_a?(Numeric) && solid['height_mm'].between?(1, 100_000)
        end
        raise RPCError.new(-32602, "Invalid solid at position #{index}")
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
