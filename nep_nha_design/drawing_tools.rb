# frozen_string_literal: true

module NepNhaDesign
  module Bridge
    # These are documented send_action names. A queued action is not a completed edit.
    NATIVE_TOOLS = {
      'select' => 'selectSelectionTool:', 'paint_bucket' => 'selectPaintTool:',
      'eraser' => 'selectEraseTool:', 'line' => 'selectLineTool:', 'freehand' => 'selectFreehandTool:',
      'rectangle' => 'selectRectangleTool:', 'rotated_rectangle' => 'selectRectangle3PointTool:',
      'circle' => 'selectCircleTool:', 'polygon' => 'selectPolygonTool:',
      'arc' => 'selectArcTool:', 'three_point_arc' => 'selectArc3PointTool:',
      'pie' => 'selectArc3PointPieTool:', 'move' => 'selectMoveTool:',
      'push_pull' => 'selectPushPullTool:', 'rotate' => 'selectRotateTool:',
      'follow_me' => 'selectExtrudeTool:', 'scale' => 'selectScaleTool:', 'offset' => 'selectOffsetTool:',
      'tape_measure' => 'selectMeasureTool:', 'dimensions' => 'selectDimensionTool:',
      'protractor' => 'selectProtractorTool:', 'text' => 'selectTextTool:', 'axes' => 'selectAxisTool:',
      'orbit' => 'selectOrbitTool:', 'zoom' => 'selectZoomTool:', 'zoom_window' => 'selectZoomWindowTool:',
      'previous_view' => 'viewUndo:', 'position_camera' => 'selectPositionCameraTool:',
      'walk' => 'selectWalkTool:', 'look_around' => 'selectTurnTool:', 'field_of_view' => 'selectFieldOfViewTool:'
    }.freeze

    class << self
      def activate_native_tool(params)
        name = params['tool']
        action = NATIVE_TOOLS[name]
        { tool: name, queued: action ? Sketchup.send_action(action) : false }
      end

      def drawing_point(values)
        unless values.is_a?(Array) && values.length == 3 &&
               values.all? { |value| value.is_a?(Numeric) && value.between?(-10_000_000, 10_000_000) }
          raise RPCError.new(-32602, 'Provide a valid XYZ coordinate in mm')
        end
        Geom::Point3d.new(values.map(&:mm))
      end

      def draw_geometry(model, params)
        # Drawing in a shared component definition could change other instances.
        raise RPCError.new(-32602, 'Exit group editing before drawing') if model.active_path

        shape = params['shape']
        points = params.fetch('points_mm', [])
        unless points.is_a?(Array) && points.size.between?(1, 256)
          raise RPCError.new(-32602, 'Provide 1–256 XYZ points')
        end
        points = points.map { |point| drawing_point(point) }
        with_operation(model) do
          group = model.entities.add_group
          group.name = params.fetch('name', shape)
          items = draw_in_group(group.entities, shape, points, params)
          raise RPCError.new(-32602, 'SketchUp could not create the requested geometry') if Array(items).empty?

          { group_id: group.persistent_id, entity_count: group.entities.length, shape: shape }
        end
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

      def drawing_text(params)
        value = params['text']
        raise RPCError.new(-32602, 'Provide annotation text') unless value.is_a?(String) && value.length.between?(1, 300)

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
        raise RPCError.new(-32602, 'Exit group editing before editing') if model.active_path

        selected = model.selection.to_a
        ids = params['ids']
        unless ids.is_a?(Array) && ids.length.between?(1, 128) && ids.all? { |id| id.is_a?(Integer) } &&
               selected.map(&:persistent_id).sort == ids.sort
          raise RPCError.new(-32602, 'Selection changed. Select the intended objects and send again.')
        end
        if selected.any? { |entity| entity.respond_to?(:locked?) && entity.locked? }
          raise RPCError.new(-32602, 'Selection includes a locked entity')
        end

        action = params['action']
        with_operation(model) do
          case action
          when 'erase', 'hide', 'soften', 'unsoften'
            unless selected.all? { |entity| entity.is_a?(Sketchup::Edge) }
              raise RPCError.new(-32602, 'Select only the edges to edit')
            end
            if action == 'erase'
              model.entities.erase_entities(selected)
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
            return_component_id = instance.persistent_id
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
          when 'rotate', 'scale', 'flip'
            transform_drawing(model.entities, selected, action, params)
          else
            raise RPCError.new(-32602, 'Unsupported edit')
          end
          { action: action, affected: selected.length, component_id: return_component_id }.compact
        end
      end

      def transform_drawing(entities, selected, action, params)
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
                      axis = %w[x y z].index(params['axis_name'])
                      raise RPCError.new(-32602, 'Select X, Y or Z as the mirror plane normal') unless axis

                      factors = [1, 1, 1]
                      factors[axis] = -1
                      Geom::Transformation.scaling(pivot, *factors)
                    end
        entities.transform_entities(transform, selected)
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
        case params['action']
        when 'extents'
          view.zoom_extents
        when 'selection'
          raise RPCError.new(-32602, 'Select geometry to frame') if model.selection.empty?

          view.zoom(model.selection)
        when 'zoom'
          factor = params['factor']
          raise RPCError.new(-32602, 'Zoom factor must be between 1 and 10') unless factor.is_a?(Numeric) && factor.between?(1, 10)

          view.zoom(factor)
        when 'position'
          eye, target, up = %w[eye_mm target_mm up].map { |key| drawing_point(params[key]) }
          up -= ORIGIN
          unless (target - eye).cross(up).valid?
            raise RPCError.new(-32602, 'Camera direction and up vector must be noncollinear')
          end
          camera = Sketchup::Camera.new(eye, target, up)
          if params.key?('fov_deg') && !params['fov_deg'].nil?
            fov = params['fov_deg']
            raise RPCError.new(-32602, 'FOV must be between 1 and 120 degrees') unless fov.is_a?(Numeric) && fov.between?(1, 120)

            camera.fov = fov
          end
          view.camera = camera
        else
          raise RPCError.new(-32602, 'Unsupported camera action')
        end
        { eye_mm: point_mm(view.camera.eye), target_mm: point_mm(view.camera.target) }
      end
    end
  end
end
