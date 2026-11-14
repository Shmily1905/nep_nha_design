# frozen_string_literal: true

module NepNhaDesign
  module Bridge
    class << self
      def add_hip_roof(entities, geometry)
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
          next if fascia.zero?

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
            wall = solids.fetch(opening.fetch('wall_index'))
            kind = opening.fetch('kind', 'door')
            if params['fit_openings'] == true
              category = kind == 'door' ? 'door' : 'window'
              parent = categories[category] ||= root.entities.add_group.tap { |item| item.name = labels.fetch(category) }
              add_opening_panel(model, parent.entities, wall, opening, palette)
            end
            next unless kind == 'door' && opening.fetch('height_mm') >= 2600

            parent = categories['window'] ||= root.entities.add_group.tap { |item| item.name = labels.fetch('window') }
            add_opening_glass(model, parent.entities, wall, opening, palette)
          end
          if params['hip_roof']
            roof = root.entities.add_group
            roof.name = 'Mái hông'
            roof.material = solid_material(model, { 'hex_color' => '#A94F3D', 'material_key' => 'Mái ngói' }, palette)
            add_hip_roof(roof.entities, params['hip_roof'])
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

      def selected_wall(model, id)
        wall = model.selection.to_a.first if model.selection.length == 1
        unless (wall.is_a?(Sketchup::Group) || wall.is_a?(Sketchup::ComponentInstance)) &&
               wall.persistent_id == id && !wall.locked? && wall.manifold?
          raise RPCError.new(-32602, 'Chọn đúng một group/component tường kín (Solid) và mở khóa.')
        end
        wall
      end

      def inspect_wall(model, params)
        wall = selected_wall(model, params['wall_id'])
        faces = wall.definition.entities.grep(Sketchup::Face)
        sides = faces.filter_map do |face|
          points = face.outer_loop.vertices.map { |vertex| vertex.position.transform(wall.transformation) }
          next unless points.length.between?(3, 32)

          points.map { |point| point_mm(point).map { |value| value.round(2) } }
        end
        { wall_id: wall.persistent_id, name: wall.name,
          bounds_mm: { min: point_mm(wall.bounds.min), max: point_mm(wall.bounds.max) },
          coordinate_space: 'active editing context', face_count: faces.length, face_loops_mm: sides.first(48) }
      end

      public :inspect_wall

      def cut_existing_wall(model, params)
        wall = selected_wall(model, params['wall_id'])
        if Array(model.active_path).any? { |parent| parent.locked? || parent.definition.instances.length != 1 }
          raise RPCError.new(-32602, 'Hãy mở khóa và Make Unique nhóm/component cha trước khi khoét.')
        end

        bounds = wall.bounds
        data = { 'category' => 'wall', 'name' => wall.name, 'base_mm' => bounds.min.z.to_mm,
                 'height_mm' => bounds.depth.to_mm }
        opening = params['opening']
        raise RPCError.new(-32602, 'Thiếu thông số ô mở.') unless opening.is_a?(Hash)

        opening = opening.merge('wall_index' => 0)
        validate_opening(opening, [data])
        entities = model.active_entities
        with_operation(model) do
          material = wall.material
          layer = wall.layer
          shadows = [wall.casts_shadows?, wall.receives_shadows?]
          attributes = wall.attribute_dictionaries&.flat_map { |dictionary|
            dictionary.map { |key, value| [dictionary.name, key, value] }
          } || []
          cut = cut_wall_opening(entities, wall, data, opening)
          cut.layer = layer
          cut.material = material
          cut.casts_shadows, cut.receives_shadows = shadows
          attributes.each do |dictionary, key, value|
            next if %w[SU_InstanceSet SU_DefinitionSet].include?(dictionary)

            cut.set_attribute(dictionary, key, value)
          end
          glass = add_opening_glass(model, entities, data, opening, {})
          model.selection.clear
          model.selection.add(cut)
          { wall_id: cut.persistent_id, fixed_glass_id: glass&.persistent_id, height_mm: opening['height_mm'] }
        end
      end

      def add_opening_panel(model, entities, wall, opening, palette)
        door = opening.fetch('kind', 'door') == 'door'
        height = opening.fetch('height_mm')
        height = 2400 if door && height >= 2600
        # Inset the panel 3 mm at the jambs and leave a 3 mm clearance top and bottom.
        a, b = opening.values_at('start_mm', 'end_mm')
        width = Math.hypot(b[0] - a[0], b[1] - a[1])
        gap = a.zip(b).map { |start, finish| (finish - start) * 3.0 / width }
        inset = opening.merge('start_mm' => a.zip(gap).map(&:sum),
                              'end_mm' => b.zip(gap).map { |value, delta| value - delta })
        panel = {
          'name' => door ? 'Cánh cửa đi' : 'Kính cửa sổ',
          'footprint_mm' => opening_polygon(inset, door ? [40, opening.fetch('wall_thickness_mm')].min : 10),
          'base_mm' => wall.fetch('base_mm') + opening.fetch('sill_mm', 0) + 3,
          'height_mm' => height - 6,
          'hex_color' => door ? '#8C6248' : '#77BDD6',
          'opacity' => door ? 1.0 : 0.45,
          'material_key' => door ? 'Gỗ cửa' : 'Kính cố định'
        }
        extrude_solid(entities, panel).material = solid_material(model, panel, palette)
      end

      def add_opening_glass(model, entities, wall, opening, palette)
        height = opening.fetch('height_mm')
        return unless opening.fetch('kind', 'door') == 'door' && height >= 2600

        glass = {
          'name' => 'Ô kính cố định trên cửa', 'footprint_mm' => opening_polygon(opening, 10),
          'base_mm' => wall.fetch('base_mm') + opening.fetch('sill_mm', 0) + 2400,
          'height_mm' => height - 2400, 'hex_color' => '#77BDD6',
          'material_key' => 'Kính cố định', 'opacity' => 0.45
        }
        group = extrude_solid(entities, glass)
        group.material = solid_material(model, glass, palette)
        group
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
