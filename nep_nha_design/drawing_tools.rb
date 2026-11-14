# frozen_string_literal: true

module NepNhaDesign
  module Bridge
    class << self
      def drawing_point(values)
        unless values.is_a?(Array) && values.length == 3 &&
               values.all? { |value| value.is_a?(Numeric) && value.between?(-10_000_000, 10_000_000) }
          raise RPCError.new(-32602, 'Provide a valid XYZ coordinate in mm')
        end
        Geom::Point3d.new(values.map(&:mm))
      end

      def draw_geometry(model, params)
        raise RPCError.new(-32602, 'Exit group editing before drawing') if model.active_path

        id = params['operation_id']
        name = drawing_text(params, 'name', 100)
        items = params['items']
        unless id.is_a?(String) && id.match?(/\A[a-zA-Z0-9_-]{1,64}\z/) &&
               items.is_a?(Array) && items.size.between?(1, 32)
          raise RPCError.new(-32602, 'Provide an operation ID and 1–32 objects')
        end
        fingerprint = Digest::SHA256.hexdigest(JSON.generate(params))
        existing = model.entities.grep(Sketchup::Group).find do |group|
          group.get_attribute('NepNhaDesign', 'drawing_id') == id
        end
        if existing
          unless existing.get_attribute('NepNhaDesign', 'drawing_input') == fingerprint
            raise RPCError.new(-32602, 'Operation ID already used for a different drawing')
          end
          return drawing_summary(existing, false)
        end
        with_operation(model) do
          root = model.entities.add_group
          root.name = name
          root.set_attribute('NepNhaDesign', 'generated_drawing', true)
          root.set_attribute('NepNhaDesign', 'drawing_id', id)
          root.set_attribute('NepNhaDesign', 'drawing_input', fingerprint)
          if block_given?
            yield root.entities
          else
            items.each { |item| add_drawing_item(model, root.entities, item) }
          end
          drawing_summary(root, true)
        end
      end

      def build_hip_roof(model, params)
        panels = params['roof_faces_mm']
        unless panels.is_a?(Array) && panels.size.between?(1, 512) &&
               panels.all? { |panel| panel.is_a?(Array) && panel.size.between?(3, 64) } &&
               params['pitch'].is_a?(Numeric) && params['pitch'].between?(1, 80) &&
               params['height_mm'].is_a?(Numeric) && params['height_mm'].abs <= 10_000_000 &&
               params['overhang_mm'].is_a?(Numeric) && params['overhang_mm'].between?(0, 10_000) &&
               params['fascia_mm'].is_a?(Numeric) && params['fascia_mm'].between?(0, 3000)
          raise RPCError.new(-32602, 'Invalid hip roof geometry')
        end
        panels.flatten(1).each { |point| drawing_point(point) }
        draw_geometry(model, params.merge('name' => 'Mái hông', 'items' => [nil])) do |entities|
          roof = entities.add_group
          roof.name = 'Mái hông'
          roof.set_attribute('NepNhaDesign', 'generated_drawing', true)
          add_hip_roof(roof.entities, params)
        end
      end

      def add_drawing_item(model, parent, item)
        raise RPCError.new(-32602, 'Expected an object specification') unless item.is_a?(Hash)

        name = drawing_text(item, 'name', 100)
        shape = item['shape']
        points = item.fetch('points_mm', [])
        unless points.is_a?(Array) && points.size.between?(1, shape == 'mesh' ? 4096 : 256)
          raise RPCError.new(-32602, "Invalid point count for #{name}")
        end
        points = points.map { |point| drawing_point(point) }
        group = parent.add_group
        group.name = name
        group.set_attribute('NepNhaDesign', 'generated_drawing', true)
        entities = group.entities
        result = case shape
                 when 'mesh' then draw_mesh(entities, points, item)
                 when 'sweep' then draw_sweep(entities, points, item)
                   when 'extrusion'
                   distance = item['depth_mm']
                   if points.size >= 3 && distance.is_a?(Numeric) && distance.abs.between?(0.1, 100_000)
                     face = entities.add_face(points)
                     if face
                       direction = drawing_point(item['direction']) - ORIGIN
                       unless direction.valid? && direction.parallel?(face.normal)
                         raise RPCError.new(-32602, 'Extrusion direction must be normal to its profile')
                       end
                       face.reverse! unless face.normal.samedirection?(direction)
                       face.pushpull(distance.mm)
                       true
                     end
                   end
                 else draw_in_group(entities, shape, points, item)
                 end
        if !result || Array(result).empty? || entities.length.zero?
          raise RPCError.new(-32602, "SketchUp could not create #{name}")
        end
        if (item['solid'] == true || shape == 'extrusion') && !group.manifold?
          raise RPCError.new(-32602, "#{name}: kết quả không phải Solid kín")
        end
        assign_drawing_assets(model, group, item)
        group
      end

      def assign_drawing_assets(model, group, item)
        if item['material']
          material = model.materials[item['material'].to_s]
          raise RPCError.new(-32602, 'Material does not exist') unless material

          group.material = material
        end
        if item['tag']
          tag = model.layers[item['tag'].to_s]
          raise RPCError.new(-32602, 'Tag does not exist') unless tag

          group.layer = tag
        end
      end

      def drawing_summary(root, created)
        { group_id: root.persistent_id, created: created, bounds_mm: drawing_bounds(root),
          objects: root.entities.grep(Sketchup::Group).map do |group|
            { id: group.persistent_id, name: group.name, solid: group.manifold?,
              bounds_mm: drawing_bounds(group), faces: group.entities.grep(Sketchup::Face).length }
          end }
      end

      def drawing_bounds(item)
        box = item.bounds
        { min: point_mm(box.min), max: point_mm(box.max) } if box.valid?
      end

      def draw_mesh(entities, points, item)
        faces = item['faces']
        unless faces.is_a?(Array) && faces.size.between?(1, 8192)
          raise RPCError.new(-32602, 'Provide 1–8192 polygon faces')
        end
        mesh = Geom::PolygonMesh.new(points.size, faces.size)
        indices = points.map { |point| mesh.add_point(point) }
        if indices.uniq.size != indices.size
          raise RPCError.new(-32602, 'Mesh vertices must be unique; reuse their indices')
        end
        faces.each do |face|
          unless face.is_a?(Array) && face.size.between?(3, 180) && face.uniq.size == face.size &&
                 face.all? { |index| index.is_a?(Integer) && index.between?(0, points.size - 1) }
            raise RPCError.new(-32602, 'Invalid polygon indices')
          end
          mesh.add_polygon(face.map { |index| indices[index] })
        end
        entities.add_faces_from_mesh(mesh, 0)
        unless entities.grep(Sketchup::Face).size == faces.size
          raise RPCError.new(-32602, 'Mesh has invalid faces; triangulate non-planar polygons')
        end
        angle = item['smooth_angle_deg']
        if angle.is_a?(Numeric) && angle.between?(0, 90) && angle.positive?
          entities.grep(Sketchup::Edge).each do |edge|
            pair = edge.faces
            if pair.size == 2 && pair[0].normal.angle_between(pair[1].normal) <= angle.degrees
              edge.soft = edge.smooth = true
            end
          end
        end
        true
      end

      def draw_sweep(entities, profile, item)
        path = item['path_mm']
        unless profile.size >= 3 && path.is_a?(Array) && path.size.between?(2, 256)
          raise RPCError.new(-32602, 'Sweep needs a closed profile and 2–256 path points')
        end
        path = path.map { |point| drawing_point(point) }
        unique = path.first == path.last ? path[0...-1] : path
        if unique.map(&:to_a).uniq.size != unique.size || (path.first == path.last && unique.size < 3)
          raise RPCError.new(-32602, 'Sweep path must be one continuous unbranched chain or loop')
        end
        face = entities.add_face(profile)
        first_segment = path[1] - path[0]
        unless face && first_segment.valid? && face.normal.parallel?(first_segment) && path[0].on_plane?(face.plane)
          raise RPCError.new(-32602, 'Place a planar profile normal to the first path segment, at its start')
        end
        edges = entities.add_curve(path)
        unless edges.size == path.size - 1 && face.valid? && face.followme(edges)
          raise RPCError.new(-32602, 'Follow Me failed; check the path for bends or intersections')
        end
        leftovers = edges.select { |edge| edge.valid? && edge.faces.empty? }
        entities.erase_entities(leftovers) unless leftovers.empty?
        true
      end
      def draw_in_group(entities, shape, points, params)
        case shape
        when 'line'
          entities.add_line(*points) if points.size == 2
        when 'freehand'
          entities.add_curve(points) if points.size >= 2
        when 'rectangle', 'rotated_rectangle', 'face'
          entities.add_face(points) if shape == 'face' ? points.size >= 3 : points.size == 4
        when 'two_point_arc', 'three_point_arc'
          draw_arc_through_points(entities, points, params)
        when 'circle', 'polygon', 'arc', 'pie'
          draw_radial(entities, shape, points, params)
        when 'offset'
          draw_offset(entities, points, params)
        when 'angle_guide'
          return unless points.size == 3

          origin, reference, plane_point = points
          direction = reference - origin
          normal = direction.cross(plane_point - origin)
          angle = params['sweep_deg']
          unless normal.valid? && angle.is_a?(Numeric) && angle.between?(-360, 360)
            raise RPCError.new(-32602, 'Provide a valid angle and drawing plane')
          end
          transform = Geom::Transformation.rotation(origin, normal, angle.degrees)
          entities.add_cline(origin, reference.transform(transform))
        when 'guide_line'
          entities.add_cline(*points) if points.size == 2
        when 'guide_point'
          entities.add_cpoint(points.first) if points.size == 1
        when 'dimension'
          entities.add_dimension_linear(points[0], points[1], points[2] - ORIGIN) if points.size == 3
        when 'text'
          entities.add_text(drawing_text(params), points.first) if points.size == 1
        when 'text_3d'
          return unless points.size == 1

          height = params['height_mm']
          raise RPCError.new(-32602, 'Invalid text height') unless height.is_a?(Numeric) && height.between?(1, 10_000)
          depth = params.fetch('depth_mm', 0)
          raise RPCError.new(-32602, 'Invalid text extrusion') unless depth.is_a?(Numeric) && depth.between?(0, 10_000)
          if entities.add_3d_text(drawing_text(params), TextAlignLeft, 'Arial', false, false,
                                  height.mm, 0, 0, true, depth.mm)
            entities.transform_entities(Geom::Transformation.translation(points.first - ORIGIN), entities.to_a)
            entities.to_a
          end
        end
      end

      def draw_offset(entities, points, params)
        distance = params['offset_mm']
        unless points.size >= 3 && points.uniq.size == points.size &&
               points.all? { |point| (point.z - points.first.z).abs < 0.001.mm } &&
               distance.is_a?(Numeric) && distance.abs.between?(0.1, 100_000)
          raise RPCError.new(-32602, 'Offset needs a simple horizontal polygon and a signed distance')
        end
        polygon = points.map { |point| [point.x.to_f, point.y.to_f] }
        polygon_area = ->(loop) do
          loop.zip(loop.rotate).sum { |(x, y), (nx, ny)| x * ny - y * nx }
        end
        area = polygon_area.call(polygon)
        if area.abs < 1e-8 || offset_self_intersects?(polygon)
          raise RPCError.new(-32602, 'Offset source must be a simple polygon')
        end
        signed = distance.mm.to_f * (area.positive? ? 1 : -1)
        vectors = []
        lines = polygon.zip(polygon.rotate).map do |a, b|
          dx, dy = b.zip(a).map { |last, first| last - first }
          length = Math.hypot(dx, dy)
          raise RPCError.new(-32602, 'Offset edge too short') if length < 0.1.mm

          vectors << [dx, dy]
          [dy / length, -dx / length, (dy * a[0] - dx * a[1]) / length + signed]
        end
        result = lines.rotate(-1).zip(lines).map do |(a, b, c), (d, e, f)|
          determinant = a * e - b * d
          if determinant.abs < 1e-8
            raise RPCError.new(-32602, 'Remove redundant collinear vertices before offsetting')
          end
          [(c * e - b * f) / determinant, (a * f - c * d) / determinant]
        end
        reversed = result.zip(result.rotate, vectors).any? do |a, b, (dx, dy)|
          (b[0] - a[0]) * dx + (b[1] - a[1]) * dy <= 0
        end
        if reversed || polygon_area.call(result) * area <= 0 || offset_self_intersects?(result)
          raise RPCError.new(-32602, 'Offset collapses or self-intersects; reduce distance or split the contour')
        end
        boundary = result.map { |x, y| Geom::Point3d.new(x, y, points.first.z) }
        params['filled'] == true ? entities.add_face(boundary) : entities.add_curve(boundary + [boundary.first])
      end

      def offset_self_intersects?(points)
        segments = points.zip(points.rotate)
        cross = ->(a, b, c) { (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) }
        segments.each_with_index.any? do |(a, b), i|
          segments.each_with_index.any? do |(c, d), j|
            next false if j <= i + 1 || (i.zero? && j == segments.size - 1)

            overlap = [0, 1].all? do |axis|
              [a[axis], b[axis]].min <= [c[axis], d[axis]].max &&
                [c[axis], d[axis]].min <= [a[axis], b[axis]].max
            end
            overlap && cross.call(a, b, c) * cross.call(a, b, d) <= 0 &&
              cross.call(c, d, a) * cross.call(c, d, b) <= 0
          end
        end
      end

      def drawing_text(params, key = 'text', limit = 300)
        value = params[key]
        raise RPCError.new(-32602, "Provide valid #{key}") unless value.is_a?(String) && value.strip.length.between?(1, limit) && value.length <= limit

        value
      end

      def draw_arc_through_points(entities, points, params)
        return unless points.size == 3

        start, middle, finish = points
        u = middle - start
        v = finish - start
        normal = u.cross(v)
        raise RPCError.new(-32602, 'Arc points must not be collinear') unless normal.valid?

        denominator = 2.0 * normal.dot(normal)
        first = v.cross(normal).to_a.map { |value| value * u.dot(u) / denominator }
        second = normal.cross(u).to_a.map { |value| value * v.dot(v) / denominator }
        center = start + Geom::Vector3d.new(first.zip(second).map(&:sum))
        radial = start - center
        ending = finish - center
        sweep = Math.atan2(normal.normalize.dot(radial.cross(ending)), radial.dot(ending)) % (2 * Math::PI)
        entities.add_arc(center, radial, normal, radial.length, 0, sweep, drawing_segments(params))
      end

      def drawing_segments(params)
        segments = params.fetch('segments', 24)
        unless segments.is_a?(Integer) && segments.between?(3, 180)
          raise RPCError.new(-32602, 'Segments must be between 3 and 180')
        end
        segments
      end

      def draw_radial(entities, shape, points, params)
        return unless points.size == 3

        center, radial, plane_point = points
        axis = radial - center
        normal = axis.cross(plane_point - center)
        raise RPCError.new(-32602, 'Radius and plane points must be noncollinear') unless normal.valid?

        segments = drawing_segments(params)
        case shape
        when 'circle', 'polygon'
          edges = if shape == 'circle'
                    entities.add_circle(center, normal, axis.length, segments)
                  else
                    # add_ngon chooses a starting direction itself. Explicit points preserve the requested first vertex.
                    points = segments.times.map do |index|
                      radial.transform(Geom::Transformation.rotation(center, normal, 2 * Math::PI * index / segments))
                    end
                    entities.add_curve(points + [points.first])
                  end
          if params['filled'] == true && !entities.add_face(edges)
            raise RPCError.new(-32602, 'SketchUp could not fill the requested shape')
          end
          edges
        else
          sweep = params['sweep_deg']
          unless sweep.is_a?(Numeric) && sweep > 0 && sweep < 360
            raise RPCError.new(-32602, 'Arc sweep must be greater than 0 and less than 360 degrees')
          end
          edges = entities.add_arc(center, axis, normal, axis.length, 0, sweep.degrees, segments)
          if shape == 'pie'
            endpoint = radial.transform(Geom::Transformation.rotation(center, normal, sweep.degrees))
            edges += [entities.add_line(center, radial), entities.add_line(center, endpoint)]
            raise RPCError.new(-32602, 'SketchUp could not close the pie') unless entities.add_face(edges)
          end
          edges
        end
      end

      def edit_drawing(model, params)
        if Array(model.active_path).any? { |parent| parent.locked? || parent.definition.instances.length != 1 }
          raise RPCError.new(-32602, 'Unlock and Make Unique each parent before editing its contents')
        end

        selected = model.selection.to_a
        ids = params['ids']
        unless ids.is_a?(Array) && ids.length.between?(1, 100) && ids.uniq == ids &&
               ids.all? { |id| id.is_a?(Integer) }
          raise RPCError.new(-32602, 'Provide unique drawing IDs')
        end
        active = model.active_entities
        action = params['action']
        if selected.map(&:persistent_id).sort != ids.sort
          selected = ids.map { |id| model.find_entity_by_persistent_id(id) }
          generated = selected.all? do |item|
            next false unless item.is_a?(Sketchup::Group) && item.get_attribute('NepNhaDesign', 'generated_drawing')

            item.parent == active.parent
          end
          unless action != 'erase' && generated
            raise RPCError.new(-32602, 'Select the exact existing objects before editing')
          end
        end
        if selected.any? { |entity| entity.respond_to?(:locked?) && entity.locked? }
          raise RPCError.new(-32602, 'Selection includes a locked entity')
        end

        selected = ids.map { |id| selected.find { |entity| entity.persistent_id == id } }
        component_id = nil
        result_id = nil
        with_operation(model) do
          case action
          when 'erase', 'hide', 'soften', 'unsoften'
            unless selected.all? { |entity| entity.is_a?(Sketchup::Edge) }
              raise RPCError.new(-32602, 'Select only the edges to edit')
            end
            if action == 'erase'
              active.erase_entities(selected)
            elsif action == 'hide'
              selected.each { |edge| edge.hidden = true }
            else
              selected.each { |edge| edge.soft = edge.smooth = (action == 'soften') }
            end
          when 'paint'
            material = model.materials[params['material'].to_s]
            unless material && selected.all? { |entity| entity.is_a?(Sketchup::Face) ||
                entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance) }
              raise RPCError.new(-32602, 'Select faces or instances and specify an existing material')
            end
            selected.each do |entity|
              if entity.is_a?(Sketchup::Face) && params['back'] == true
                entity.back_material = material
              else
                entity.material = material
              end
            end
          when 'component'
            unless selected.length == 1 && selected.first.is_a?(Sketchup::Group)
              raise RPCError.new(-32602, 'Select one group to convert to a component')
            end
            instance = selected.first.to_component
            component_id = instance.persistent_id
          when 'make_unique'
            unless selected.all? { |entity| entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance) }
              raise RPCError.new(-32602, 'Select groups or components to make unique')
            end
            selected.each(&:make_unique)
          when 'position_texture'
            face = selected.first
            material = model.materials[params['material'].to_s]
            maps = params['mapping']
            unless selected.size == 1 && face.is_a?(Sketchup::Face) && material&.texture &&
                   maps.is_a?(Array) && maps.size.between?(2, 4)
              raise RPCError.new(-32602, 'Select one face, a textured material and 2–4 mapping pairs')
            end
            points = maps.flat_map do |xyz, uv|
              point = drawing_point(xyz)
              unless point.on_plane?(face.plane) && uv.is_a?(Array) && uv.size == 2 &&
                     uv.all? { |value| value.is_a?(Numeric) && value.between?(-10_000_000, 10_000_000) }
                raise RPCError.new(-32602, 'Texture anchors must lie on the face plane and have valid UV coordinates')
              end
              [point, Geom::Point3d.new(uv[0], uv[1], 0)]
            end
            unless face.position_material(material, points, params['back'] != true)
              raise RPCError.new(-32602, 'SketchUp could not map this texture')
            end
          when 'follow_me'
            profile, *extra = selected.grep(Sketchup::Face)
            edges = selected.grep(Sketchup::Edge)
            path = params['path_ids']
            unless profile && extra.empty? && edges.length + 1 == selected.length &&
                   path.is_a?(Array) && !path.empty? && path.sort == edges.map(&:persistent_id).sort
              raise RPCError.new(-32602, 'Select one face and the ordered path edges')
            end
            by_id = edges.to_h { |edge| [edge.persistent_id, edge] }
            ordered = path.map { |id| by_id.fetch(id) }
            unless ordered.each_cons(2).all? { |first, second| (first.vertices & second.vertices).length == 1 }
              raise RPCError.new(-32602, 'Follow Me requires a contiguous path')
            end
            raise RPCError.new(-32602, 'SketchUp could not sweep the profile') unless profile.followme(ordered)
          when 'tag'
            tag = model.layers[params['tag'].to_s]
            unless tag && selected.all? { |entity| entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance) }
              raise RPCError.new(-32602, 'Select groups or components and specify an existing tag')
            end
            selected.each { |entity| entity.layer = tag }
          when 'push_pull'
            distance = params['distance_mm']
            unless selected.length == 1 && selected.first.is_a?(Sketchup::Face) &&
                   distance.is_a?(Numeric) && distance.between?(-100_000, 100_000) && !distance.zero?
              raise RPCError.new(-32602, 'Select one face and specify a nonzero distance')
            end
            selected.first.pushpull(distance.mm, params['copy'] == true)
          when 'move', 'rotate', 'scale', 'flip'
            if params['copy'] == true
              unless selected.all? { |entity| entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance) }
                raise RPCError.new(-32602, 'Copy requires selected groups or components')
              end
              selected = selected.map do |item|
                if item.is_a?(Sketchup::Group)
                  item.copy
                else
                  active.add_instance(item.definition, item.transformation).tap do |copy|
                    copy.name, copy.layer, copy.material = item.name, item.layer, item.material
                  end
                end
              end
            end
            transform_drawing(active, selected, action, params)
          when 'union', 'subtract', 'intersect'
            unless selected.size == 2 && selected.all? { |entity| entity.is_a?(Sketchup::Group) && entity.manifold? }
              raise RPCError.new(-32602, 'Select two Solid groups')
            end
            left, right = selected
            # trim has unambiguous cutter / target order; discard the temporary cutter on success.
            solid = case action
                    when 'union' then left.union(right)
                    when 'intersect' then left.intersect(right)
                    when 'subtract' then right.trim(left)
                    end
            raise RPCError.new(-32602, 'Boolean did not produce a closed solid') unless solid && solid.manifold?

            selected.each { |item| item.erase! if item.valid? && item != solid }
            solid.set_attribute('NepNhaDesign', 'generated_drawing', true)
            result_id = solid.persistent_id
          else
            raise RPCError.new(-32602, 'Unsupported edit')
          end
          { action: action, affected: selected.length, component_id: component_id, result_id: result_id,
            remaining_ids: selected.select(&:valid?).map(&:persistent_id) }.compact
        end
      end

      def transform_drawing(entities, selected, action, params)
        if action == 'move'
          entities.transform_entities(Geom::Transformation.translation(drawing_point(params['offset_mm']) - ORIGIN), selected)
          return
        end
        pivot = drawing_point(params['pivot_mm'])
        transform = case action
                    when 'rotate'
                      axis = drawing_point(params['axis']) - ORIGIN
                      angle = params['angle_deg']
                      unless axis.valid? && angle.is_a?(Numeric) && angle.between?(-3600, 3600)
                        raise RPCError.new(-32602, 'Provide a valid rotation axis and angle')
                      end
                      Geom::Transformation.rotation(pivot, axis, angle.degrees)
                    when 'scale'
                      factors = params['factors']
                      unless factors.is_a?(Array) && factors.length == 3 &&
                             factors.all? { |value| value.is_a?(Numeric) && value.between?(0.001, 1000) }
                        raise RPCError.new(-32602, 'Provide three positive scale factors')
                      end
                      Geom::Transformation.scaling(pivot, *factors)
                    when 'flip'
                      normal = case params['axis_name']
                               when 'x' then X_AXIS
                               when 'y' then Y_AXIS
                               when 'z' then Z_AXIS
                               else drawing_point(params['axis']) - ORIGIN
                               end
                      raise RPCError.new(-32602, 'Mirror plane normal must be nonzero') unless normal.valid?

                      x = normal.axes.first
                      frame = Geom::Transformation.axes(pivot, x, normal.cross(x), normal)
                      frame * Geom::Transformation.scaling(1, 1, -1) * frame.inverse
                    end
        entities.transform_entities(transform, selected)
      end

      def inspect_drawing(model, params)
        ids = params['ids']
        if ids && (!ids.is_a?(Array) || !ids.size.between?(1, 100) || !ids.all? { |id| id.is_a?(Integer) })
          raise RPCError.new(-32602, 'Invalid entity IDs')
        end
        items = if ids
                  ids.uniq.map { |id| model.find_entity_by_persistent_id(id) }
                elsif model.selection.empty?
                  model.active_entities.first(100)
                else
                  model.selection.to_a.first(100)
                end
        result = { units: 'mm', active_edit_context: !model.active_path.nil?, objects: items.map do |item|
          next unless item.is_a?(Sketchup::Drawingelement)

          data = { id: item.persistent_id, type: item.typename, bounds_mm: drawing_bounds(item) }
          if item.is_a?(Sketchup::Face)
            data[:outer_mm] = item.outer_loop.vertices.first(256).map { |vertex| point_mm(vertex.position) }
            data[:outer_count] = item.outer_loop.vertices.size
            data[:normal] = item.normal.to_a
          elsif item.is_a?(Sketchup::Edge)
            data[:endpoints_mm] = item.vertices.map { |vertex| point_mm(vertex.position) }
          elsif item.is_a?(Sketchup::Group) || item.is_a?(Sketchup::ComponentInstance)
            data[:name] = item.name
            data[:solid] = item.manifold?
            data[:children] = item.definition.entities.to_a.first(100).map { |child| [child.persistent_id, child.typename] }
          end
          data
        end.compact }
        unless ids
          result[:tags] = model.layers.first(150).map(&:name)
          result[:materials] = model.materials.first(150).map { |material| [material.name, !material.texture.nil?] }
        end
        result
      end

      def select_drawing(model, params)
        ids = params['ids']
        unless ids.is_a?(Array) && ids.size.between?(1, 100) && ids.uniq == ids && ids.all? { |id| id.is_a?(Integer) }
          raise RPCError.new(-32602, 'Provide unique drawing IDs')
        end
        active = model.active_entities
        selected = ids.map { |id| model.find_entity_by_persistent_id(id) }
        unless selected.all? { |item| item.is_a?(Sketchup::Drawingelement) && item.parent == active.parent }
          raise RPCError.new(-32602, 'Select only entities in the active context')
        end
        model.selection.clear
        model.selection.add(selected)
        { selection: selection_info(model) }
      end

      def measure_drawing(params)
        points = params['points_mm']
        unless points.is_a?(Array) && points.length.between?(2, 3)
          raise RPCError.new(-32602, 'Provide two points for distance or three for angle')
        end
        a, b, c = points.map { |point| drawing_point(point) }
        return { distance_mm: a.distance(b).to_mm } unless c

        u, v = a - b, c - b
        raise RPCError.new(-32602, 'Angle rays must have nonzero length') unless u.valid? && v.valid?

        { angle_deg: u.angle_between(v) * 180 / Math::PI }
      end

      def set_drawing_axes(model, params)
        raise RPCError.new(-32602, 'Exit group editing before setting model axes') if model.active_path

        origin, red, green = %w[origin_mm red_mm green_mm].map { |key| drawing_point(params[key]) }
        x_axis = red - origin
        z_axis = x_axis.cross(green - origin)
        raise RPCError.new(-32602, 'Axis points must be noncollinear') unless z_axis.valid?

        y_axis = z_axis.cross(x_axis)
        with_operation(model) { model.axes.set(origin, x_axis.normalize, y_axis.normalize, z_axis.normalize) }
        { origin_mm: point_mm(origin) }
      end

      def drawing_camera(model, params)
        view = model.active_view
        old = view.camera
        snapshot = Sketchup::Camera.new(old.eye, old.target, old.up, old.perspective?)
        if old.perspective?
          snapshot.fov = old.fov
        else
          snapshot.height = old.height
        end
        previous_snapshot = Sketchup::Camera.new(old.eye, old.target, old.up, old.perspective?)
        if old.perspective?
          previous_snapshot.fov = old.fov
        else
          previous_snapshot.height = old.height
        end
        case params['action']
        when 'extents'
          view.zoom_extents
        when 'selection'
          raise RPCError.new(-32602, 'Select geometry to frame') if model.selection.empty?

          view.zoom(model.selection)
        when 'zoom'
          factor = params['factor']
          raise RPCError.new(-32602, 'Zoom factor must be between 0.1 and 10') unless factor.is_a?(Numeric) && factor.between?(0.1, 10)

          if factor >= 1
            view.zoom(factor)
          elsif old.perspective?
            direction = old.eye - old.target
            direction.length = direction.length / factor
            eye = old.target + direction
            snapshot.set(eye, old.target, old.up)
            view.camera = snapshot
          else
            snapshot.height = old.height / factor
            view.camera = snapshot
          end
        when 'previous'
          previous = @camera_history&.last if @camera_history&.first == model
          raise RPCError.new(-32602, 'No previous MCP camera for this model') unless previous

          view.camera = previous
        when 'pan', 'walk'
          delta = drawing_point(params['delta_mm']) - ORIGIN
          delta.z = 0 if params['action'] == 'walk'
          snapshot.set(snapshot.eye + delta, snapshot.target + delta, snapshot.up)
          view.camera = snapshot
        when 'orbit', 'look'
          axis = drawing_point(params['axis']) - ORIGIN
          angle = params['angle_deg']
          unless axis.valid? && angle.is_a?(Numeric) && angle.between?(-360, 360)
            raise RPCError.new(-32602, 'Provide a nonzero rotation axis and angle')
          end

          pivot = params['action'] == 'orbit' ? old.target : old.eye
          rotation = Geom::Transformation.rotation(pivot, axis, angle.degrees)
          eye, target, up = [old.eye, old.target, old.up].map { |value| value.transform(rotation) }
          snapshot.set(eye, target, up)
          view.camera = snapshot
        when 'fov'
          fov = params['fov_deg']
          unless old.perspective? && fov.is_a?(Numeric) && fov.between?(1, 120)
            raise RPCError.new(-32602, 'Set a perspective camera and FOV between 1 and 120 degrees')
          end

          snapshot.fov = fov
          view.camera = snapshot
        when 'position'
          eye, target, up = %w[eye_mm target_mm up].map { |key| drawing_point(params[key]) }
          up -= ORIGIN
          unless (target - eye).cross(up).valid?
            raise RPCError.new(-32602, 'Camera direction and up vector must be noncollinear')
          end
          camera = Sketchup::Camera.new(eye, target, up, params['perspective'] != false)
          if params.key?('fov_deg') && !params['fov_deg'].nil?
            fov = params['fov_deg']
            raise RPCError.new(-32602, 'FOV must be between 1 and 120 degrees') unless fov.is_a?(Numeric) && fov.between?(1, 120)

            camera.fov = fov
          end
          view.camera = camera
        else
          raise RPCError.new(-32602, 'Unsupported camera action')
        end
        @camera_history = [model, previous_snapshot]
        { eye_mm: point_mm(view.camera.eye), target_mm: point_mm(view.camera.target) }
      end
    end
  end
end
