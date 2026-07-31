# 编码：UTF-8
module CiviscopeLayout
  module Core
    
    def self.do_convert_bldg
      model = Sketchup.active_model
      return if model.selection.empty?
      
      model.start_operation('转换为CIM建筑', true)
      target_layer = self.ensure_layer("CIM-mass")
      
      new_selection = []
      
      model.selection.to_a.each do |t|
        next unless t.respond_to?(:manifold?) && t.manifold?
        inst = t.is_a?(Sketchup::Group) ? t.to_component : t
        inst.layer = target_layer 
        
        inst.set_attribute("dynamic_attributes", "_formatversion", 1.0)
        inst.set_attribute("dynamic_attributes", "floor_height", "3.0")
        inst.set_attribute("dynamic_attributes", "bldg_func", DEFAULT_BLDG_FUNCS[0])
        inst.set_attribute("dynamic_attributes", "bldg_type", "塔楼")
        inst.set_attribute("dynamic_attributes", "bldg_no", "") 
        
        self.attach_observers(inst)
        self.auto_recalculate(inst, true)
        new_selection << inst
      end
      
      model.selection.clear
      model.selection.add(new_selection) unless new_selection.empty?
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

    def self.do_apply_bldg(h, f, no, type = nil, th = nil)
      @pending_recalc_entity = nil
      model = Sketchup.active_model
      model.start_operation('修改建筑属性', true)
      model.selection.to_a.each do |inst|
        next unless inst.get_attribute("dynamic_attributes", "bldg_func")

        req_th = th.to_f

        if req_th > 0
          # 恢复建筑至完整高度，以实际几何高度为基准缩放
          old_roof_sh = inst.get_attribute("dynamic_attributes", "roof_structure_height").to_f
          if old_roof_sh > 0
            CiviscopeLayout::Core.skip_recalc = true
            begin
              self.remove_roof_structure(inst)
              self.push_top_face(inst, old_roof_sh)
              inst.set_attribute("dynamic_attributes", "roof_structure_height", "0")
            ensure
              CiviscopeLayout::Core.skip_recalc = false
            end
          end

          actual_th_m = ((inst.bounds.max.z - inst.bounds.min.z) * 0.0254).round(4)
          if actual_th_m > 0 && (actual_th_m - req_th).abs > 0.01
            if inst.is_a?(Sketchup::ComponentInstance) && inst.make_unique
              ObserverManager.attach_entity_observers(inst)
            end
            scale_z = req_th / actual_th_m
            bnd = inst.bounds
            base_pt = Geom::Point3d.new(bnd.center.x, bnd.center.y, bnd.min.z)
            tr = Geom::Transformation.scaling(base_pt, 1.0, 1.0, scale_z)
            inst.transform!(tr)
          end
        end

        inst.set_attribute("dynamic_attributes", "floor_height", h.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_func", f.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_no", no.to_s)
        inst.set_attribute("dynamic_attributes", "bldg_type", type.to_s) if type
        self.update_bldg_layer(inst) if type
        self.auto_recalculate(inst, true, true)
      end
      self.refresh_stats_ui(model.selection)
      model.commit_operation
    end

    # 获取实体顶部/底部世界坐标 Z 值
    def self.get_world_z(entity, which)
      definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition
      return nil unless definition
      bounds = definition.bounds
      tr = self.get_full_world_transform(entity) rescue entity.transformation
      local_z = (which == :bottom) ? bounds.min.z : bounds.max.z
      local_pt = Geom::Point3d.new(bounds.center.x, bounds.center.y, local_z)
      world_pt = local_pt.transform(tr)
      world_pt.z * 0.0254
    end

    # 返回与 entity 同层级的所有 CIM 建筑实体
    def self.find_sibling_buildings(entity)
      siblings = []
      parent_ents = entity.parent.entities rescue nil
      return siblings unless parent_ents
      parent_ents.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        siblings << e if e.get_attribute("dynamic_attributes", "bldg_func")
      end
      siblings
    end

    # 获取实体在世界坐标系中的 XY 包围盒 [min_x, max_x, min_y, max_y]
    def self.get_world_xy_bounds(entity)
      tr = self.get_full_world_transform(entity) rescue entity.transformation
      bnd = entity.definition.bounds
      corners = [
        Geom::Point3d.new(bnd.min.x, bnd.min.y, 0),
        Geom::Point3d.new(bnd.max.x, bnd.min.y, 0),
        Geom::Point3d.new(bnd.min.x, bnd.max.y, 0),
        Geom::Point3d.new(bnd.max.x, bnd.max.y, 0),
      ]
      world_corners = corners.map { |c| c.transform(tr) }
      xs = world_corners.map(&:x)
      ys = world_corners.map(&:y)
      [xs.min, xs.max, ys.min, ys.max]
    end

    # 两个 XY 包围盒是否重叠（含容差）
    def self.xy_bounds_overlap?(bb1, bb2)
      tolerance = 0.1  # 10cm 容差，处理浮点精度
      !(bb1[1] + tolerance < bb2[0] || bb2[1] + tolerance < bb1[0] ||
        bb1[3] + tolerance < bb2[2] || bb2[3] + tolerance < bb1[2])
    end

    # 递归查找实体下方所有叠放的CIM体块（不限类型），返回高度数组
    def self.find_buildings_under_entity(entity, visited = [])
      return [] if visited.include?(entity)
      visited << entity
      heights = []

      entity_world_bottom = self.get_world_z(entity, :bottom)
      return [] if entity_world_bottom.nil?

      entity_bb = self.get_world_xy_bounds(entity)

      self.find_sibling_buildings(entity).each do |sibling|
        next if visited.include?(sibling)

        sibling_world_top = self.get_world_z(sibling, :top)
        next if sibling_world_top.nil?

        vert_diff = (entity_world_bottom - sibling_world_top).abs
        next if vert_diff >= 1.0

        sibling_bb = self.get_world_xy_bounds(sibling)
        entity_center_x = (entity_bb[0] + entity_bb[1]) / 2.0
        entity_center_y = (entity_bb[2] + entity_bb[3]) / 2.0
        center_in = entity_center_x >= sibling_bb[0] && entity_center_x <= sibling_bb[1] &&
                    entity_center_y >= sibling_bb[2] && entity_center_y <= sibling_bb[3]
        next unless center_in

        th = sibling.get_attribute("dynamic_attributes", "total_height").to_f
        heights << th
        heights.concat(self.find_buildings_under_entity(sibling, visited))
      end
      heights
    end

    # 递归查找堆叠中最顶部的体块（用于获取建筑总高）
    def self.find_top_of_stack(entity, visited = [])
      return entity if visited.include?(entity)
      visited << entity

      entity_world_top = self.get_world_z(entity, :top)
      entity_bb = self.get_world_xy_bounds(entity)

      self.find_sibling_buildings(entity).each do |sibling|
        next if visited.include?(sibling)

        sibling_world_bottom = self.get_world_z(sibling, :bottom)
        next if sibling_world_bottom.nil?

        vert_diff = (sibling_world_bottom - entity_world_top).abs
        next if vert_diff >= 1.0

        sibling_bb = self.get_world_xy_bounds(sibling)
        entity_center_x = (entity_bb[0] + entity_bb[1]) / 2.0
        entity_center_y = (entity_bb[2] + entity_bb[3]) / 2.0
        center_in = entity_center_x >= sibling_bb[0] && entity_center_x <= sibling_bb[1] &&
                    entity_center_y >= sibling_bb[2] && entity_center_y <= sibling_bb[3]
        next unless center_in

        return self.find_top_of_stack(sibling, visited)
      end

      entity
    end

    # 获取用于折减系数查询的高度（塔楼用真高，裙楼/独立用自身高度）
    def self.get_height_for_reduction(entity)
      bldg_type = entity.get_attribute("dynamic_attributes", "bldg_type") || "塔楼"
      bounds = entity.bounds
      own_th = ((bounds.max.z - bounds.min.z) * 0.0254).round(2)
      case bldg_type
      when '塔楼'
        compute_effective_h(entity, bldg_type, own_th)
      else
        own_th
      end
    end

    # 计算有效总高度 H
    def self.compute_effective_h(entity, bldg_type, own_th)
      case bldg_type
      when "独立"  # "独立"
        own_th
      when "塔楼"  # "塔楼"
        heights = self.find_buildings_under_entity(entity)
        own_th + heights.sum
      else
        own_th
      end
    end

    # 屋顶构筑物高度
    def self.compute_roof_structure_height(h)
      if h <= 100
        0.0
      elsif h <= 150
        10.0
      elsif h <= 200
        15.0
      elsif h <= 250
        20.0
      elsif h <= 300
        25.0
      else
        40.0
      end
    end

    # 避难层层数
    def self.compute_refuge_floors(h)
      h > 100 ? (h / 50.0).ceil - 1 : 0
    end

    # 计算单个体块在其堆叠区间内应分配的避难层数
    # entity: 当前体块, own_th: 体块自身高度, h_effective: 建筑真高（含下方体块）
    def self.compute_block_refuge_floors(entity, own_th, h_effective)
      top = self.find_top_of_stack(entity)
      top_type = top.get_attribute("dynamic_attributes", "bldg_type") || "塔楼"
      top_th = top.get_attribute("dynamic_attributes", "total_height").to_f
      total_height = self.compute_effective_h(top, top_type, top_th)

      return 0 if total_height <= 100

      block_base = h_effective - own_th
      block_top = h_effective
      total_segments = (total_height / 50.0).ceil
      count = 0
      (1...total_segments).each do |i|
        pos = 50.0 * i
        count += 1 if pos > block_base && pos <= block_top
      end
      count
    end

    # 推拉建筑顶面（正值=向上恢复，负值=向下切除）
    def self.push_top_face(entity, delta_m)
      return if delta_m.abs < 0.0001
      definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition
      return unless definition
      ents = definition.entities
      top_faces = ents.grep(Sketchup::Face).select { |f| f.normal.z > 0.99 }
      return if top_faces.empty?
      max_z = top_faces.map { |f| f.bounds.max.z }.max
      top_face = top_faces.find { |f| (f.bounds.max.z - max_z).abs < 0.001 }
      return unless top_face
      local_scale_z = entity.transformation.zscale
      delta_inch = (delta_m / 0.0254) / local_scale_z
      top_face.pushpull(delta_inch)
    end

    def self.remove_roof_structure(entity)
      model = Sketchup.active_model
      definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition

      roof_id_str = entity.get_attribute("civiscope", "roof_structure_id")
      if roof_id_str
        roof = model.find_entity_by_persistent_id(roof_id_str.to_i) rescue nil
        if roof && roof.valid? && roof.parent == definition
          roof.erase!
          entity.set_attribute("civiscope", "roof_structure_id", nil)
          return true
        end
      end

      # 回退：扫描 definition 内部（屋顶构筑物嵌套在建筑 definition 中）
      if definition
        old = definition.entities.grep(Sketchup::Group).select { |g|
          g.get_attribute("civiscope", "is_roof_structure")
        }
        if old.any?
          definition.entities.erase_entities(old)
          entity.set_attribute("civiscope", "roof_structure_id", nil)
          return true
        end
      end
      false
    end

    # 计算短边的 ratio 比例（用于屋顶构筑物偏移距离）
    def self.compute_short_edge_ratio(vertices, ratio)
      return 0 if vertices.length < 3
      xs = vertices.map(&:x)
      ys = vertices.map(&:y)
      short_edge = [xs.max - xs.min, ys.max - ys.min].min
      short_edge * ratio
    end

    # 将多边形顶点向内偏移（XY 平面，沿边的垂线方向）
    def self.offset_polygon_vertices(vertices, distance)
      return nil if vertices.length < 3 || distance <= 0
      z = vertices.first.z
      n = vertices.length

      # 投影到 2D
      pts = vertices.map { |v| Geom::Point3d.new(v.x, v.y, 0) }

      # 判断绕组方向
      signed_area = 0.0
      n.times { |i| j = (i + 1) % n; signed_area += pts[i].x * pts[j].y - pts[j].x * pts[i].y }
      is_ccw = signed_area > 0

      # 每条边的方向与内法线
      segs = []
      n.times do |i|
        j = (i + 1) % n
        dx = pts[j].x - pts[i].x
        dy = pts[j].y - pts[i].y
        len = Math.sqrt(dx * dx + dy * dy)
        next if len < 1e-8
        dir = Geom::Vector3d.new(dx / len, dy / len, 0)
        normal = is_ccw ? Geom::Vector3d.new(-dir.y, dir.x, 0)
                        : Geom::Vector3d.new(dir.y, -dir.x, 0)
        segs << { dir: dir, normal: normal, origin: pts[i] }
      end
      return nil if segs.length < 3

      # 相邻边的偏移线求交 → 新顶点
      result = []
      m = segs.length
      m.times do |i|
        a = segs[i]
        b = segs[(i + 1) % m]
        pa = Geom::Point3d.new(
          a[:origin].x + a[:normal].x * distance,
          a[:origin].y + a[:normal].y * distance, 0)
        pb = Geom::Point3d.new(
          b[:origin].x + b[:normal].x * distance,
          b[:origin].y + b[:normal].y * distance, 0)
        inter = Geom.intersect_line_line([pa, a[:dir]], [pb, b[:dir]])
        if inter.is_a?(Geom::Point3d)
          result << Geom::Point3d.new(inter.x, inter.y, z)
        else
          result << Geom::Point3d.new(pa.x, pa.y, z)
        end
      end

      result.uniq { |v| [v.x.round(6), v.y.round(6)] }
    end

    # 创建屋顶构筑物3D几何（仅塔楼和独立建筑）
    # 在建筑 definition 内部创建，向内偏移固定10m后向上挤出
    def self.create_roof_structure(entity, roof_structure_height_m)
      self.remove_roof_structure(entity)
      return if roof_structure_height_m <= 0

      definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition
      ents = definition.entities
      return unless ents

      top_faces = ents.grep(Sketchup::Face).select { |f| f.normal.z > 0.99 }
      return if top_faces.empty?

      max_z = top_faces.map { |f| f.bounds.max.z }.max
      top_face = top_faces.find { |f| (f.bounds.max.z - max_z).abs < 0.001 }
      return unless top_face

      local_scale_z = entity.transformation.zscale
      roof_sh_inch = (roof_structure_height_m / 0.0254) / local_scale_z

      # 读取缩进距离
      rs_mode = entity.get_attribute("dynamic_attributes", "roof_structure_mode")
      indent_m = if rs_mode == 'manual'
        manual_indent = entity.get_attribute("dynamic_attributes", "roof_structure_manual_indent").to_f
        manual_indent >= 0 ? manual_indent : 10.0
      else
        entity.get_attribute("dynamic_attributes", "bldg_func") == '居住' ? 3.0 : 10.0
      end
      # 在世界坐标系中计算偏移，避免非均匀缩放时 offset 失真
      tr = entity.transformation
      world_indent = indent_m / 0.0254

      top_verts = top_face.outer_loop.vertices.map(&:position)

      # 创建屋顶构筑物父群组
      roof_group = ents.add_group
      roof_group.name = "屋顶构筑物"
      roof_group.set_attribute("civiscope", "is_roof_structure", true)
      entity.set_attribute("civiscope", "roof_structure_id", roof_group.persistent_id.to_s)

      roof_ents = roof_group.entities

      # ---- 围墙：原屋顶轮廓边线向上挤出 ----
      wall_group = roof_ents.add_group
      wall_group.name = "围墙"
      wall_ents = wall_group.entities

      top_verts.each_with_index do |v, i|
        j = (i + 1) % top_verts.length
        v1 = top_verts[i]
        v2 = top_verts[j]
        v3 = Geom::Point3d.new(v2.x, v2.y, v2.z + roof_sh_inch)
        v4 = Geom::Point3d.new(v1.x, v1.y, v1.z + roof_sh_inch)
        wall_ents.add_face(v1, v2, v3, v4)
      end

      # ---- 内缩体块：顶面向内偏移后向上挤出 ----
      world_verts = top_verts.map { |v| v.transform(tr) }
      world_inner = offset_polygon_vertices(world_verts, world_indent)
      inner_verts = world_inner ? world_inner.map { |v| v.transform(tr.inverse) } : nil
      if inner_verts && inner_verts.length >= 3
        inner_group = roof_ents.add_group
        inner_group.name = "内缩体块"
        inner_ents = inner_group.entities

        inner_face = inner_ents.add_face(inner_verts)
        if inner_face
          inner_face.reverse! if inner_face.normal.z < 0
          inner_face.pushpull(roof_sh_inch)
        end
      end
    end

    def self.calc_bldg_data(entity, skip_operation = false)
      @pending_recalc_entity = nil
      UI.stop_timer(@skip_recalc_restore_timer_id) if @skip_recalc_restore_timer_id
      CiviscopeLayout::Core.skip_recalc = true

      # 确保定义独立，避免复制体之间相互影响
      made_unique = false
      if entity.is_a?(Sketchup::ComponentInstance) && entity.make_unique
        ObserverManager.attach_entity_observers(entity)
        made_unique = true
      end

      model = Sketchup.active_model
      model.start_operation('更新体块数据', true, true, true) unless skip_operation

      begin
        # 恢复建筑至完整高度，移除旧屋顶构筑物，确保为干净的 manifold solid
        old_roof_sh = entity.get_attribute("dynamic_attributes", "roof_structure_height").to_f
        had_roof = old_roof_sh > 0
        if had_roof
          self.remove_roof_structure(entity)
          self.push_top_face(entity, old_roof_sh)
        end

        is_manifold = entity.manifold?
        # 注意：不在此处 return——分层线 group 会破坏 manifold 检查，
        # 若直接 return 则永远无法清理旧分层线。后续 push_top_face 和
        # create_roof_structure 在找不到顶面时会安全跳过，不会崩溃。
        fh = entity.get_attribute("dynamic_attributes", "floor_height").to_f
        return if fh <= 0

        bldg_type = entity.get_attribute("dynamic_attributes", "bldg_type") || "塔楼"

        # 建筑已恢复完整高度，bounds 反映真实总高
        bounds = entity.bounds
        th_m = ((bounds.max.z - bounds.min.z) * 0.0254).round(2)

        h_effective = self.compute_effective_h(entity, bldg_type, th_m)
        roof_sh = self.compute_roof_structure_height(h_effective)
        refuge_fl = self.compute_block_refuge_floors(entity, th_m, h_effective)

        # 手动/自动模式处理
        rs_mode = entity.get_attribute("dynamic_attributes", "roof_structure_mode")
        if rs_mode == 'manual'
          manual_h = entity.get_attribute("dynamic_attributes", "roof_structure_manual_height").to_f
          roof_sh = manual_h if manual_h >= 0
        else
          # 居住建筑：真高≥100m时屋顶构筑物高5m，<100m时为0
          bldg_func = entity.get_attribute("dynamic_attributes", "bldg_func")
          roof_sh = 5.0 if bldg_func == '居住' && h_effective >= 100
        end


        # 非堆叠顶部体块不生成屋顶构筑物
        unless entity == self.find_top_of_stack(entity)
          roof_sh = 0
        end
        has_roof = (bldg_type == "塔楼" || bldg_type == "独立") && roof_sh > 0

        physical_floors = th_m > roof_sh ? ((th_m - roof_sh) / fh).floor : 0
        fc = physical_floors - refuge_fl
        fc = 0 if fc < 0

        # 使用底面面积（比体积/高度更精确）
        # 注意：definition 内的面面积为局部坐标，需乘以 XY 缩放因子
        definition = entity.is_a?(Sketchup::Group) ? entity.definition : entity.definition
        bottom_faces = definition.entities.grep(Sketchup::Face).select { |f| f.normal.z < -0.99 }
        if bottom_faces.any?
          min_z = bottom_faces.map { |f| f.bounds.min.z }.min
          b_area_sq_inch = bottom_faces.select { |f| (f.bounds.min.z - min_z).abs < 0.001 }.sum(&:area)
          tr = entity.transformation
          b_area = (b_area_sq_inch * tr.xscale * tr.yscale * (0.0254 ** 2)).round(2)
        else
          vol_m3 = entity.volume * (0.0254 ** 3)
          b_area = th_m > 0 ? (vol_m3 / th_m).round(2) : 0
        end
        t_area = (fc * b_area).round(2)

        need_update = (entity.get_attribute("dynamic_attributes", "bldg_area") != t_area.to_s) ||
                      (entity.get_attribute("dynamic_attributes", "floor_count") != fc.to_s) ||
                      (entity.get_attribute("dynamic_attributes", "base_area") != b_area.to_s) ||
                      (entity.get_attribute("dynamic_attributes", "total_height") != th_m.to_s) ||
                      (entity.get_attribute("dynamic_attributes", "roof_structure_height") != roof_sh.to_s) ||
                      (entity.get_attribute("dynamic_attributes", "refuge_floors") != refuge_fl.to_s)

        if need_update
          if has_roof
            self.push_top_face(entity, -roof_sh)
            fl_roof_sh = 0
          else
            fl_roof_sh = roof_sh
          end

          entity.set_attribute("dynamic_attributes", "total_height", th_m.to_s)
          entity.set_attribute("dynamic_attributes", "floor_count", fc.to_s)
          entity.set_attribute("dynamic_attributes", "base_area", b_area.to_s)
          entity.set_attribute("dynamic_attributes", "bldg_area", t_area.to_s)
          entity.set_attribute("dynamic_attributes", "roof_structure_height", roof_sh.to_s)
          entity.set_attribute("dynamic_attributes", "refuge_floors", refuge_fl.to_s)

          self.update_floor_lines(entity, physical_floors, fh, fl_roof_sh)

          if has_roof
            self.create_roof_structure(entity, roof_sh)
          end
        else
          # 无需更新，恢复原有切除状态
          if had_roof
            self.push_top_face(entity, -old_roof_sh)
            self.create_roof_structure(entity, old_roof_sh)
          end
        end
      ensure
        model.commit_operation unless skip_operation
        @skip_recalc_restore_timer_id = UI.start_timer(0.25, false) do
          @skip_recalc_restore_timer_id = nil
          CiviscopeLayout::Core.skip_recalc = false
        end
      end
    end

    def self.update_floor_lines(entity, floor_count, floor_height_m, roof_structure_height_m = 0)

      # 确保定义独立，避免复制体之间相互影响
      if entity.is_a?(Sketchup::ComponentInstance) && entity.make_unique
        ObserverManager.attach_entity_observers(entity)
        puts "[DEBUG-FL] update_floor_lines made_unique=true"
      end

      ents = (entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)) ? entity.definition.entities : nil
      unless ents
        return
      end

      # Clear old floor lines (both legacy edges and new group style)
      old_edges = ents.grep(Sketchup::Edge).select { |e| e.get_attribute("civiscope", "is_floor_line") }
      ents.erase_entities(old_edges) if old_edges.any?

      old_groups = ents.grep(Sketchup::Group).select { |g|
        g.get_attribute("civiscope", "is_floor_lines_group") || g.name == "Floor Lines"
      }

      old_groups.each { |g|
        g.erase! if g.valid?
      }

      floor_count = floor_count.to_i
      return if floor_count <= 1

      # 排除屋顶构筑物内部的边线（避免 max_z 受屋顶构筑物影响）
      roof_groups = ents.grep(Sketchup::Group).select { |g| g.get_attribute("civiscope", "is_roof_structure") }
      roof_edges = roof_groups.flat_map { |g| g.entities.grep(Sketchup::Edge) }
      building_edges = ents.grep(Sketchup::Edge) - roof_edges
      vertex_zs = building_edges.flat_map { |e| [e.start.position.z, e.end.position.z] }
      return if vertex_zs.empty?

      min_z = vertex_zs.min
      max_z = vertex_zs.max

      # Detect base edges (usually the perimeter)
      base_faces = ents.grep(Sketchup::Face).select do |f|
        f.normal.z < -0.99 && (f.bounds.min.z - min_z).abs < 0.001
      end

      if base_faces.empty?
        base_edges = ents.grep(Sketchup::Edge).select do |e|
          (e.start.position.z - min_z).abs < 0.001 && (e.end.position.z - min_z).abs < 0.001
        end
      else
        base_edges = base_faces.flat_map(&:edges).uniq
        base_edges.select! do |e|
          (e.start.position.z - min_z).abs < 0.001 && (e.end.position.z - min_z).abs < 0.001
        end
      end

      # Only keep outer edges of the building mass
      base_edges.select! do |e|
        faces = e.faces
        base_face_count = faces.count { |f| f.normal.z.abs > 0.99 && (f.bounds.min.z - min_z).abs < 0.001 }
        base_face_count < 2
      end

      return if base_edges.empty?

      # Account for local Z scale to keep lines consistent in meters
      local_scale_z = entity.transformation.zscale
      local_fh_inch = (floor_height_m / 0.0254) / local_scale_z

      # 屋顶构筑物高度不参与分层线切分
      local_roof_sh_inch = (roof_structure_height_m / 0.0254) / local_scale_z
      effective_max_z = max_z - local_roof_sh_inch

      # 将分层线放在独立 group 中，避免 add_line 分裂建筑立面破坏 solid
      floor_group = ents.add_group
      floor_group.name = "Floor Lines"
      floor_group.layer = CiviscopeLayout::Core.ensure_layer("000-分层线")
      floor_group.set_attribute("civiscope", "is_floor_lines_group", true)

      (1..floor_count).each do |i|
        z_offset = i * local_fh_inch
        cur_z = min_z + z_offset

        break if cur_z > effective_max_z

        base_edges.each do |e|
          pt1 = e.start.position
          pt2 = e.end.position
          p1 = Geom::Point3d.new(pt1.x, pt1.y, cur_z)
          p2 = Geom::Point3d.new(pt2.x, pt2.y, cur_z)

          line = floor_group.entities.add_line(p1, p2)
          line.set_attribute("civiscope", "is_floor_line", true) if line
        end
      end

    end
  end

end
