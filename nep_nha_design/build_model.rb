# frozen_string_literal: true

module NepNhaDesign
  module Bridge
    class << self
      def build_auto_concept(model, geometry)
        raise ArgumentError, 'Hãy thoát chế độ chỉnh sửa group trước khi dựng.' if model.active_path

        footprint = geometry.fetch('footprint_mm')
        height = geometry.fetch('height_mm')
        roof_faces = geometry.fetch('roof_faces_mm')
        unless valid_footprint?(footprint) && height.is_a?(Numeric) && height.between?(500, 30_000)
          raise ArgumentError, 'Đường bao hoặc chiều cao tầng không hợp lệ.'
        end

        with_operation(model) do
          root = model.entities.add_group
          root.name = 'Concept ngoại thất Nếp Nhà'
          body = root.entities.add_group
          body.name = 'Thân nhà'
          palette = {}
          body.material = solid_material(model, { 'hex_color' => '#E6DFD2', 'material_key' => 'Tường sơn' }, palette)
          face = body.entities.add_face(footprint.map { |x, y| Geom::Point3d.new(x.mm, y.mm, 0) })
          raise ArgumentError, 'SketchUp không tạo được mặt đường bao.' unless face

          face.reverse! if face.normal.z < 0
          face.pushpull(height.mm)
          bounds = body.bounds
          unless body.manifold? && bounds.min.z.to_mm.abs < 0.1 && (bounds.max.z.to_mm - height).abs < 0.1
            raise ArgumentError, 'SketchUp không tạo được khối thân nhà đúng cao độ.'
          end

          roof_status = :unsupported
          if roof_faces.any?
            roof = root.entities.add_group
            roof.name = 'Mái hông'
            roof.material = solid_material(model, { 'hex_color' => '#A94F3D', 'material_key' => 'Mái ngói' }, palette)
            begin
              add_concept_roof(roof.entities, geometry)
              roof_status = :built
            rescue StandardError => e
              roof.erase!
              roof_status = :failed
              warn "[Nếp Nhà Design] Concept roof: #{e.class}: #{e.message}"
            end
          end
          { width: bounds.width.to_mm.round, depth: bounds.height.to_mm.round, roof: roof_status }
        end
      end

      def add_concept_roof(entities, geometry)
        geometry.fetch('roof_faces_mm').each do |polygon|
          surface = entities.add_face(polygon.map { |point| Geom::Point3d.new(point.map(&:mm)) })
          raise ArgumentError, 'SketchUp không tạo được mặt dốc của mái.' unless surface

          surface.reverse! if surface.normal.z < 0
        end
        pitch = geometry.fetch('pitch') * Math::PI / 180
        eave = geometry.fetch('height_mm') - geometry.fetch('overhang_mm') * Math.tan(pitch)
        fascia = geometry.fetch('fascia_mm').mm
        eave_segments = []
        entities.grep(Sketchup::Edge).each do |edge|
          faces = edge.faces
          if faces.length == 2 && faces[0].normal.samedirection?(faces[1].normal)
            edge.hidden = true
          elsif faces.length == 1
            a, b = edge.vertices.map(&:position)
            eave_segments << [a, b] if [a, b].all? { |point| (point.z.to_mm - eave).abs < 0.1 }
          end
        end
        eave_segments.each do |a, b|
          entities.add_face(a, b, Geom::Point3d.new(b.x, b.y, b.z - fascia),
                            Geom::Point3d.new(a.x, a.y, a.z - fascia))
        end
      end

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
        openings = params.fetch('openings', [])
        unless openings.is_a?(Array) && openings.length <= 100
          raise RPCError.new(-32602, 'Invalid openings list')
        end
        openings.each { |opening| validate_opening(opening, solids) }
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
          parents = {}
          groups = Array.new(solids.length)
          # Build every wall before making any cuts or inserting components.
          add_solid = lambda do |solid, index|
            category = solid['category']
            parent = root
            if labels.key?(category)
              parent = categories[category] ||= root.entities.add_group.tap { |item| item.name = labels.fetch(category) }
            end
            parents[index] = parent
            groups[index] = extrude_solid(parent.entities, solid)
          end
          solids.each_with_index { |solid, index| add_solid.call(solid, index) if solid['category'] == 'wall' }
          openings.each do |opening|
            index = opening.fetch('wall_index')
            parent = parents.fetch(index)
            groups[index] = cut_wall_opening(parent.entities, groups[index], solids[index], opening)
          end
          solids.each_with_index do |solid, index|
            add_solid.call(solid, index) unless solid['category'] == 'wall'
            groups[index].material = solid_material(model, solid, palette)
          end
          openings.each do |opening|
            next unless opening.fetch('kind', 'door') == 'door' && opening.fetch('height_mm') >= 2600

            wall = solids.fetch(opening.fetch('wall_index'))
            glass = {
              'name' => 'Ô kính cố định trên cửa', 'footprint_mm' => opening_polygon(opening, 10),
              'base_mm' => wall.fetch('base_mm') + opening.fetch('sill_mm', 0) + 2400,
              'height_mm' => opening.fetch('height_mm') - 2400, 'hex_color' => '#77BDD6',
              'material_key' => 'Kính cố định', 'opacity' => 0.45
            }
            parent = categories['window'] ||= root.entities.add_group.tap { |item| item.name = labels.fetch('window') }
            extrude_solid(parent.entities, glass).material = solid_material(model, glass, palette)
          end
          build_summary(root, id, scale, true)
        end
      end

      def extrude_solid(entities, solid)
        group = entities.add_group
        group.name = solid.fetch('name')
        bottom = solid.fetch('base_mm')
        height = solid.fetch('height_mm')
        points = solid.fetch('footprint_mm').map { |x, y| Geom::Point3d.new(x.mm, y.mm, bottom.mm) }
        face = group.entities.add_face(points)
        raise RPCError.new(-32602, "Invalid footprint for #{group.name}") unless face

        face.reverse! if face.normal.z < 0
        face.pushpull(height.mm)
        bounds = group.bounds
        unless group.manifold? && (bounds.min.z.to_mm - bottom).abs < 0.1 &&
               (bounds.max.z.to_mm - bottom - height).abs < 0.1
          raise RPCError.new(-32602, "Could not extrude #{group.name}")
        end
        group
      end

      def solid_material(model, solid, palette)
        key = solid['material_key']
        color = solid.fetch('hex_color').upcase
        opacity = solid.fetch('opacity', 1.0).to_f
        palette[[key, color, opacity]] ||= begin
          name = "Nếp Nhà #{[key, color, opacity].compact.join(' ')}"
          rgb = color[1..].scan(/../).map { |part| part.to_i(16) }
          material = model.materials[name]
          unless material && !material.texture && material.color.to_a.first(3) == rgb &&
                 (material.alpha - opacity).abs < 0.0001
            material = model.materials.add(name)
            material.color = Sketchup::Color.new(*rgb)
            material.alpha = opacity
          end
          material
        end
      end

      def validate_opening(opening, solids)
        if opening.is_a?(Hash)
          index = opening['wall_index']
          wall = solids[index] if index.is_a?(Integer) && index.between?(0, solids.length - 1)
          points = opening.values_at('start_mm', 'end_mm')
          sill = opening.fetch('sill_mm', 0)
          height = opening['height_mm']
          depth = opening['wall_thickness_mm']
          kind = opening.fetch('kind', 'door')
          if wall && wall['category'] == 'wall' &&
             points.all? { |point| point.is_a?(Array) && point.length == 2 &&
               point.all? { |value| value.is_a?(Numeric) && value.between?(-1_000_000, 1_000_000) } } &&
             Math.hypot(points[0][0] - points[1][0], points[0][1] - points[1][1]) >= 50 &&
             sill.is_a?(Numeric) && sill >= 0 && height.is_a?(Numeric) &&
             height >= 50 && sill + height < wall.fetch('height_mm') &&
             depth.is_a?(Numeric) && depth.between?(20, 3000) &&
             ((kind == 'door' && sill.zero? && [2200, 2400, 2600, 2700, 2800].include?(height)) ||
               (kind == 'window' && sill > 0))
            return
          end
        end
        raise RPCError.new(-32602, 'Invalid wall opening dimensions, elevation or wall index')
      end

      def opening_polygon(opening, depth)
        ax, ay = opening.fetch('start_mm')
        bx, by = opening.fetch('end_mm')
        length = Math.hypot(bx - ax, by - ay)
        dx = -(by - ay) * depth / (2.0 * length)
        dy = (bx - ax) * depth / (2.0 * length)
        [[ax + dx, ay + dy], [bx + dx, by + dy], [bx - dx, by - dy], [ax - dx, ay - dy]]
      end

      def cut_wall_opening(entities, wall_group, wall, opening)
        sill = opening.fetch('sill_mm', 0)
        below_base = sill.zero? ? 10 : 0
        thickness = opening.fetch('wall_thickness_mm')
        height = opening.fetch('height_mm')
        cutter = extrude_solid(entities, {
          'name' => 'Opening cutter', 'footprint_mm' => opening_polygon(opening, thickness + 20),
          'base_mm' => wall.fetch('base_mm') + sill - below_base, 'height_mm' => height + below_base
        })
        before = wall_group.volume
        a, b = opening.values_at('start_mm', 'end_mm')
        width = Math.hypot(a[0] - b[0], a[1] - b[1])
        expected = width.mm * thickness.mm * height.mm
        result = cutter.trim(wall_group)
        unless result && result.manifold? && (before - result.volume - expected).abs <= expected * 0.005
          raise RPCError.new(-32602, "Could not cut through #{wall.fetch('name')}; verify wall thickness and opening position")
        end
        cutter.erase! if cutter.valid?
        result.name = wall.fetch('name')
        result
      end

      def validate_solid(solid, index)
        if solid.is_a?(Hash)
          polygon = solid['footprint_mm']
          name = solid['name']
          color = solid['hex_color']
          opacity = solid.fetch('opacity', 1.0)
          key = solid['material_key']
          return if name.is_a?(String) && name.length.between?(1, 100) && valid_footprint?(polygon) &&
                    color.is_a?(String) && color.match?(/\A#[0-9a-fA-F]{6}\z/) &&
                    (key.nil? || (key.is_a?(String) && key.length.between?(1, 100))) &&
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
